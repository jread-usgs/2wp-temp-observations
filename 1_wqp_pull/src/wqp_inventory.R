#' Create a task table to call whatWQPdata across all states
#'
#' Depending on the size of the request, calls to WQP may need to be
#' partitioned based on record size. This gets the inventory of data available
#' on WQP that we need to fullfil our "needs" - which is a series of
#' site/variable combinations. The national pull no longer works, so we 
#' partition calls to whatWQPdata by state, with an error catch that splits
#' the pull in half (by counties) if it fails the first time. 
#'
#' @param states A states dataframe that includes all states you want to pull, 
#' and the corresponding counties.
#' @param final_target Name of output from task table that contains the combined
#' inventory from all states.
#' @return A dataframe returned by the function dataRetrieval::whatWQPdata, with
#'   one row per site/variable combination and the 'resultCount' being the
#'   variable from which we will make decisions about partitioning data pull
#'   requests.
do_inventory_tasks <- function(states, final_target, ...) {
  
  task_name <- unique(states$state_id)
  
  # define tasks
  download_step <- create_task_step(
    step_name = 'download',
    target_name = function(task_name, ...) {
      sprintf('%s_site_inventory', task_name)
    },
    command = function(task_name, ...) {
      sprintf("inventory_wqp(state_id = I('%s'), wqp_pull_params = wqp_pull_parameters)", task_name)
    }
  )
  
  # create task plan
  task_plan <- create_task_plan(
    task_names = task_name, 
    task_steps = list(download_step),
    add_complete = FALSE,
    final_steps = 'download'
  )
  
  # Create the task remakefile
  create_task_makefile(
    task_plan = task_plan,
    makefile = 'wqp_inventory_tasks.yml',
    include = 'remake.yml',
    sources = c(...),
    packages = c('dplyr', 'dataRetrieval', 'xml2'),
    tickquote_combinee_objects = TRUE,
    finalize_funs = 'combine_inventory',
    final_targets = final_target,
    as_promises = TRUE)
  
  # build tasks
  
  scmake('wqp_inventory.feather.ind_promise', remake_file='wqp_inventory_tasks.yml')

  
}

inventory_wqp <- function(state_id, wqp_pull_params) {
  
  # function to keep track of time it takes to pull, and 
  # number of rows in each return
  wqp_call <- function(fun, args) {
    time <- system.time(out <- do.call(fun, args))
    info <- list(
      time = time[['elapsed']],
      nrow = nrow(out),
      out = out
    )
    return(info)
  }
  wqp_args <- wqp_pull_params
  
  # collapse all constituents into single vector
  wqp_args$characteristicName <- as.character(unlist(wqp_args$characteristicName))
  
  # set state ID
  wqp_args$statecode <- state_id
  
  # Print state-specific message so user can see progress
  message('Retrieving whatWQPdata for state ', state_id)
  
  # first try the full state pull, wrapped in try so function does not fail
  # with an error. 
  temp_dat <- try(wqp_call(whatWQPdata, wqp_args[c('characteristicName', 'statecode')]))
  
  # catch errors, and break up data into two calls as a backup plan
  # this splits the call into half by counties
  if(!'list' %in% class(temp_dat)) {
    message('State call failed, calling by 1/2 of counties at a time.')
    state_counties <- filter(dataRetrieval::countyCd, STATE %in% gsub('US:', '', state_id))
    
    # split counties in half and make a 2-part call
    split <- ceiling(nrow(state_counties)/2)
    
    # first half of counties
    wqp_args$countycode <- paste('US', state_counties$STATE, state_counties$COUNTY, sep = ':')[1:split]
    temp1 <- wqp_call(whatWQPdata, wqp_args[c('characteristicName', 'countycode')])
    
    # second half of counties
    wqp_args$countycode <- paste('US', state_counties$STATE, state_counties$COUNTY, sep = ':')[(split+1):nrow(state_counties)]
    temp2 <- wqp_call(whatWQPdata, wqp_args[c('characteristicName', 'countycode')])
    
    # combine outputs
    temp_dat <- list(time = temp1$time + temp2$time,
                     nrow = nrow(temp1$out) + nrow(temp2$out),
                     out = bind_rows(temp1$out, temp2$out))
  }
  
  # summarize what was retrieved and how long it took
  message('Retrieved ', temp_dat$nrow, ' rows of data in ', ceiling(temp_dat$time), ' seconds.')
  
  return(temp_dat$out)
}
combine_inventory <- function(ind_file, ...) {
  dat_out <- bind_rows(...)
  
  # keep columns of interest, put back lat/long
  # keeping lat/long here in case there was a situation where you'd want to 
  # take stock/map sites before pulling data
  dat_out <- dat_out %>%
    select(OrganizationIdentifier, MonitoringLocationIdentifier, ResolvedMonitoringLocationTypeName, 
           StateName, CountyName, HUCEightDigitCode, latitude = lat, longitude = lon, resultCount)

  # write and indicate the data file
  data_file <- scipiper::as_data_file(ind_file)
  feather::write_feather(dat_out, data_file)
  gd_put(ind_file)
}
get_states <- function(states_url) {
  
  # get state and county codes
  county_states <- dataRetrieval::countyCd %>%
    mutate(state_id = paste0('US:', STATE))
  
  state_codes <- xml2::read_xml(states_url)
  states <- unlist(as.character(xml2::xml_children(state_codes)))
  states <- stringr::str_extract(states, pattern = 'US:\\d{2}')
  states <- states[!is.na(states)]
  
  return(filter(county_states, state_id %in% states))
}

summarize_wqp_inventory <- function(inv_ind, out_file) {
 
   wqp_inventory <- feather::read_feather(sc_retrieve(inv_ind, remake_file = 'getters.yml'))
   
   all <- data.frame(n_sites = nrow(wqp_inventory), 
                     n_records = sum(wqp_inventory$resultCount), stringsAsFactors = FALSE)
   
   readr::write_csv(all, out_file)
      
}

#' Partition calls to WQP based on number of records available in WQP and a
#' number of records that is a reasonable call to WQP.
#'
#' @param partitions_ind Filename of the partitions indicator file to create.
#' @param inventory_ind .ind filename of a table with WQP record counts (from
#'   the output of dataRetrieval::whatWQPdata).
#' @param wqp_pull_params List of lists that contain parameters of interest
#'   (e.g., temperature) and all corresponding synonyms available in WQP (e.g.,
#'   "Temperature" and "Temperature, water"), plus other pull parameters.
#' @param wqp_partition_config YAML file containing an element called
#'   $target_pull_size, giving the maximum number of records that should be in a
#'   single call to WQP.
#' @return Nothing useful is returned; however, this function (1) Writes to
#'   partitions_ind a table having the same number of rows as wqp_needs - e.g.,
#'   for each site/variable combination. The dataframe stores the number of
#'   observations for that site/variable in WQP and the unique task identifier
#'   that partitions site/variables into WQP pulls.
partition_wqp_inventory <- function(partitions_ind, wqp_pull_params, inventory_ind, wqp_partition_cfg, pull_date) {
  
  # Read in the inventory & config
  wqp_inventory <- feather::read_feather(sc_retrieve(inventory_ind, 'getters.yml'))
  wqp_partition_config <- wqp_partition_cfg
  
  # filter out site types that are not of interest
  
  wqp_inventory <- wqp_inventory %>%
    filter(!(ResolvedMonitoringLocationTypeName %in% wqp_pull_params$DropLocationTypeName))
  
  # filter out bad org names
  # these orgs cause "Frequest failed [400]" errors
  bad_orgs <- grep(' |\\.|/', wqp_inventory$OrganizationIdentifier, value = TRUE)
  bad_orgs_sites <- filter(wqp_inventory, OrganizationIdentifier %in% bad_orgs)
  
  if (nrow(bad_orgs_sites) > 0){
    message(sprintf("**dropping %s sites and %s results due to bad MonIDs", nrow(bad_orgs_sites), sum(bad_orgs_sites$resultCount)))
  }
  
  wqp_inventory <- filter(wqp_inventory, !OrganizationIdentifier %in% bad_orgs)
  
  # Define the atomic_groups to use in setting up data pull partitions. An
  # atomic group is a combination of parameters that can't be reasonably split
  # into multiple WQP pulls. We're defining the atomic groups as distinct
  # combinations of constituent (a group of characteristicNames) and NHD-based
  # site ID
  atomic_groups <- wqp_inventory %>%
    #group_by(site_id) %>%
    #summarize(LakeNumObs=sum(resultCount)) %>%
    arrange(desc(resultCount))
  
  # Partition the full pull into sets of atomic groups that form right-sized
  # partitions. Use an old but fairly effective paritioning heuristic: pick
  # the number of partitions desired, sort the atomic groups by descending
  # size, and then go down the list, each time adding the next atomic group to
  # the partition that's currently smallest. With this approach we can balance
  # the distribution of data across partitions while ensuring that each site's
  # observations are completely contained within one file.
  
  # Decide how many partitions to create. This will be (A) the number of sites
  # (or lakes) with more observations than the target partition size, because
  # each of these sites/lakes will get its own partition + (B) the number of
  # remaining observations divided by the target partition size.
  target_pull_size <- wqp_partition_config$target_pull_size
  target_site_size <- wqp_partition_config$target_inv_size
  n_single_site_partitions <- filter(atomic_groups, resultCount >= target_pull_size) %>% nrow()
  n_multi_site_partitions_byresult <- filter(atomic_groups, resultCount < target_pull_size) %>%
    pull(resultCount) %>%
    { ceiling(sum(.)/target_pull_size) }
  
  # take into account ~1000 sites per pull
  n_multi_site_partitions_bysite <- nrow(filter(atomic_groups, resultCount < target_pull_size))/target_site_size
  n_multi_site_partitions <- ceiling(ifelse(n_multi_site_partitions_bysite >= n_multi_site_partitions_byresult, n_multi_site_partitions_bysite, n_multi_site_partitions_byresult))
  
  num_partitions <- n_single_site_partitions + n_multi_site_partitions
  
  # Assign each site to a partition. Sites with huge numbers
  # of observations will each get their own partition.
  partition_sizes <- rep(0, num_partitions)
  partition_site_sizes <- rep(0, num_partitions)
  assignments <- rep(NA, nrow(atomic_groups)) 
  partition_index <- 1:num_partitions
  
  # use a vector rather than adding a col to atomic_groups b/c it'll be way faster
  for(i in 1:nrow(atomic_groups)) {
    indexing_true <- partition_index[partition_site_sizes < target_site_size]
    smallest_partition_nonindexed <- which.min(partition_sizes[partition_site_sizes < target_site_size])
    smallest_partition <- indexing_true[smallest_partition_nonindexed]
    
    assignments[i] <- smallest_partition
    size_i <- atomic_groups[[i,"resultCount"]]
    partition_sizes[smallest_partition] <- partition_sizes[smallest_partition] + size_i
    partition_site_sizes[smallest_partition] <- partition_site_sizes[smallest_partition] + 1
  }
  
  
  # Prepare one data_frame containing info about each site, including
  # the pull, constituent, and task name (where task name will become the core
  # of the filename)

  partitions <- atomic_groups %>%
    mutate(
      PullDate = pull_date,
      PullTask = sprintf('%s_%04d', pull_date, assignments)) %>%
    left_join(select(wqp_inventory, MonitoringLocationIdentifier, SiteNumObs=resultCount), by='MonitoringLocationIdentifier') %>%
    select(MonitoringLocationIdentifier, SiteNumObs, PullTask, PullDate)
  
  
  # Also write the data_frame to a location that will get overwritten with
  # each new pass through this function
  feather::write_feather(partitions, scipiper::as_data_file(partitions_ind))
  gd_put(partitions_ind) # 1-arg version requires scipiper 0.0.11+
}


summarize_wqp_data <- function(data_ind, out_file) {
  
  wqp_dat <- readRDS(sc_retrieve(data_ind, 'getters.yml'))
  
  wqp_summary <- data.frame(n_obs = nrow(wqp_dat),
                            n_sites = length(unique(wqp_dat$MonitoringLocationIdentifier)))
  
  readr::write_csv(wqp_summary, out_file)
  
}

