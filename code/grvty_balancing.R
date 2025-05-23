#' Calculate balancing factors for gravity model
#'
#' @param od_zones A data frame with origins and destinations
#' @param friction A data frame with friction factors for each O-D pair
#' @param zone_id Name of ID column in od_zones
#' @param zone_o Name of origins column in od_zones
#' @param zone_d Name of destinations column in od_zones
#' @param friction_o_id Name of column with origin ID in friction
#' @param friction_d_id Name of column with destination ID in friction
#' @param friction_factor Name of column with friction factor in friction
#' @param tolerance Acceptable error (percentage)
#' @param max_iter Maximum number of iterations
#' @return A list of two data frames, one with the flows and one with convergence data
#'
#' @export
#'
#' @importFrom magrittr |>
#'
#' @examples
#' result <- grvty_balancing(od_zones = salt_lake_zones,
#'                           friction = salt_lake_friction,
#'                           zone_id = "GEOID",
#'                           zone_o = "hbo_prod",
#'                           zone_d = "hbo_attr_bal",
#'                           friction_o_id = "fromId",
#'                           friction_d_id = "toId",
#'                           friction_factor = "F_HBO",
#'                           tolerance = 0.01,
#'                           max_iter = 100000)
#'
#'

grvty_balancing <- function(od_zones,
                            friction,
                            zone_id,
                            zone_o,
                            zone_d,
                            friction_o_id,
                            friction_d_id,
                            friction_factor,
                            tolerance,
                            max_iter) {
  
  # for quick tests
  # od_zones <- trip_gen
  # friction <- skim
  # zone_id <- "GEOID"
  # zone_o <- "hbo_trip_prod"
  # zone_d <- "hbo_bal_attr"
  # friction_o_id <- "from_GEOID"
  # friction_d_id <- "to_GEOID"
  # friction_factor <- "F_HBO"
  # tolerance <- 0.01
  # max_iter <- 100
  
  # rename and select columns
  wip_friction <- friction |>
    dplyr::rename(o_id = tidyselect::all_of(friction_o_id),
                  d_id = tidyselect::all_of(friction_d_id),
                  factor = tidyselect::all_of(friction_factor)) |>
    dplyr::select(o_id, d_id, factor)
  
  wip_zones <- od_zones |>
    dplyr::rename(id = tidyselect::all_of(zone_id),
                  origin = tidyselect::all_of(zone_o),
                  destin = tidyselect::all_of(zone_d)) |>
    dplyr::mutate(origin = origin,
                  destin = destin) |>
    dplyr::select(id, origin, destin)
  
  # get minimum non-zero value for friction factor
  min_factor <- min(wip_friction$factor[wip_friction$factor != 0])
  
  # replace zero values for friction factors
  if(sum(wip_friction$factor == 0) > 0) {
    warning("\nReplacing friction factors of zero with the lowest non-zero friction factor.\n")
    wip_friction <- wip_friction |>
      # set all zero friction values equal to the smallest non-zero value
      dplyr::mutate(factor = ifelse(factor == 0, min_factor, factor))
  }
  
  # warn and remove friction rows where the friction factor is missing or undefined
  if(sum(is.na(wip_friction$factor)) > 0 |
     sum(is.infinite(wip_friction$factor)) > 0) {
    warning("\nIgnoring origin-destination pairs with missing or undefined friction factors.\n")
    wip_friction <- wip_friction |>
      dplyr::filter(!is.na(wip_friction$factor) &
                      !is.infinite(wip_friction$factor))
  }
  
  # Check that no zones are repeated in the zones table
  if(length(wip_zones$id) > length(unique(wip_zones$id))) {
    warning("\nDuplicated zone IDs in zones table. Aggregating origins and destinations by zone ID.\n")
    wip_zones <- wip_zones |>
      dplyr::group_by(id) |>
      dplyr::summarise(origin = sum(origin),
                       destin = sum(destin))
  }
  
  # Check that no OD pairs are repeated in the friction table
  wip_friction$combined_id <- paste0(as.character(wip_friction$o_id),
                                     as.character(wip_friction$d_id))
  if(length(wip_friction$combined_id) > length(unique(wip_friction$combined_id))) {
    warning("\nAverageing friction factors across duplicated origin-destination pairs in friction table.\n")
    wip_friction <- wip_friction |>
      dplyr::group_by(combined_id) |>
      dplyr::summarise(factor = mean(factor))
  }
  
  # Check that all the zones in the skim are in the zone table.
  # If they are missing from the zone table, remove them from the skim.
  unique_friction_ids <- unique(c(wip_friction$o_id, wip_friction$d_id))
  missing_from_zones <- unique_friction_ids[!unique_friction_ids %in% wip_zones$id]
  if(length(missing_from_zones > 0)) {
    missing_from_zones_warning = paste0("\nRemoving ",
                                        length(missing_from_zones),
                                        " zones from the friction data frame that are missing",
                                        " from the origin-destination table.\n")
    warning(missing_from_zones_warning)
    wip_friction <- wip_friction |>
      dplyr::filter(o_id %in% wip_zones$id,
                    d_id %in% wip_zones$id)
  }
  
  # Check that all zones in the zone table are in the skim.
  # If they are missing from the skim, remove them from the zone table
  missing_from_friction <- wip_zones$id[!wip_zones$id %in% unique_friction_ids]
  if(length(missing_from_friction > 0)) {
    missing_from_friction_warning = paste0("Removing ",
                                           length(missing_from_friction),
                                           " zones from the origin-destination data",
                                           " frame that are missing",
                                           " from the friction factor table.")
    warning(missing_from_friction_warning)
    wip_zones <- wip_zones |>
      dplyr::filter(id %in% unique_friction_ids)
  }
  
  # Replace missing origins and destinations with zeros
  if(sum(is.na(wip_zones$origin)) > 0) {
    warning("\nReplacing missing orgin values with zeros.\n")
    wip_zones <- wip_zones |>
      tidyr::replace_na(list(origin = 0))
  }
  if(sum(is.na(wip_zones$destin)) > 0) {
    warning("\nReplacing missing destination values with zeros.\n")
    wip_zones <- wip_zones |>
      tidyr::replace_na(list(destin = 0))
  }
  
  # Check whether origin and destination totals are consistent
  if(sum(wip_zones$origin) != sum(wip_zones$destin)) {
    warning(paste0("\nTotal number of origins does not equal total number of destinations.\n",
                   "Rescaling destinations for consistency with total origins.\n"))
    wip_zones$destin = wip_zones$destin *
      (sum(wip_zones$origin)/sum(wip_zones$destin))
  }
  
  # scale up so all values are greater than 10^-100
  if (min_factor < 10^-100) {
    wip_friction <- wip_friction |>
      dplyr:: mutate(factor = factor * (10^-100 / min_factor))
  }
  
  # Add productions and attractions to trip matrix
  origins <- wip_zones |>
    dplyr::select(id, origin)
  
  destinations <- wip_zones |>
    dplyr::select(id, destin)
  
  flows <- wip_friction |>
    dplyr::left_join(origins, by = c("o_id" = "id")) |>
    dplyr::left_join(destinations, by = c("d_id" = "id")) |>
    dplyr::rename(friction = factor)
  
  # first iteration
  message("\nBalancing iteration 1")
  flows <- flows |>
    dplyr::mutate(B_factor = 1)
  
  flows <- flows |>
    dplyr::group_by(o_id) |>
    dplyr::mutate(A_factor = 1/sum(B_factor * destin * friction)) |>
    dplyr::mutate(flow = A_factor * origin * B_factor * destin * friction) |>
    dplyr::ungroup()
  
  balance_check_o <- flows |>
    dplyr::group_by(o_id) |>
    dplyr::summarize(target = mean(origin),
                     value = sum(flow)) |>
    dplyr::ungroup() |>
    dplyr::mutate(diff = (value - target) / target) |>
    tidyr::replace_na(list(diff = 0)) |>
    dplyr::summarize(max_o_diff = max(abs(diff)))
  
  balance_check_d <- flows |>
    dplyr::group_by(d_id) |>
    dplyr::summarize(target = mean(destin),
                     value = sum(flow)) |>
    dplyr::ungroup() |>
    dplyr::mutate(diff = (value - target) / target) |>
    tidyr::replace_na(list(diff = 0)) |>
    dplyr::summarize(max_d_diff = max(abs(diff)))
  
  balance_check <- tibble::tibble(iteration = 1,
                                  max_o_diff = round(balance_check_o$max_o_diff[1],4),
                                  max_d_diff = round(balance_check_d$max_d_diff[1],4))
  
  # Loop for the rest of the iterations
  done <- FALSE
  i <- 2
  while (!done) {
    message(paste0("\nBalancing iteration ", i))
    flows <- flows |>
      dplyr::group_by(d_id) |>
      dplyr::mutate(B_factor = 1 / sum(A_factor * origin * friction)) |>
      dplyr::mutate(flow = A_factor * origin * B_factor * destin * friction) |>
      dplyr::ungroup()
    
    balance_check_o <- flows |>
      dplyr::group_by(o_id) |>
      dplyr::summarize(target = mean(origin),
                       value = sum(flow)) |>
      dplyr::ungroup() |>
      dplyr::mutate(diff = (value - target) / target) |>
      tidyr::replace_na(list(diff = 0)) |>
      dplyr::summarize(max_o_diff = max(abs(diff)))
    
    balance_check_d <- flows |>
      dplyr::group_by(d_id) |>
      dplyr::summarize(target = mean(destin),
                       value = sum(flow)) |>
      dplyr::ungroup() |>
      dplyr::mutate(diff = (value - target) / target) |>
      tidyr::replace_na(list(diff = 0)) |>
      dplyr::summarize(max_d_diff = max(abs(diff)))
    
    next_balance_check <- tibble::tibble(iteration = i,
                                         max_o_diff =
                                           round(balance_check_o$max_o_diff[1],4),
                                         max_d_diff =
                                           round(balance_check_d$max_d_diff[1],4))
    
    balance_check <- rbind(balance_check, next_balance_check)
    
    i <- i + 1
    
    message(paste0("\nBalancing iteration ", i))
    flows <- flows |>
      dplyr::group_by(o_id) |>
      dplyr::mutate(A_factor = 1 / sum(B_factor * destin * friction)) |>
      dplyr::mutate(flow = A_factor * origin * B_factor * destin * friction) |>
      dplyr::ungroup()
    
    balance_check_o <- flows |>
      dplyr::group_by(o_id) |>
      dplyr::summarize(target = mean(origin),
                       value = sum(flow)) |>
      dplyr::ungroup() |>
      dplyr::mutate(diff = (value - target) / target) |>
      tidyr::replace_na(list(diff = 0)) |>
      dplyr::summarize(max_o_diff = max(abs(diff)))
    
    balance_check_d <- flows |>
      dplyr::group_by(d_id) |>
      dplyr::summarize(target = mean(destin),
                       value = sum(flow)) |>
      dplyr::ungroup() |>
      dplyr::mutate(diff = (value - target) / target) |>
      tidyr::replace_na(list(diff = 0)) |>
      dplyr::summarize(max_d_diff = max(abs(diff)))
    
    next_balance_check <- tibble::tibble(iteration = i,
                                         max_o_diff =
                                           round(balance_check_o$max_o_diff[1],4),
                                         max_d_diff =
                                           round(balance_check_d$max_d_diff[1],4))
    
    balance_check <- rbind(balance_check, next_balance_check)
    
    i <- i + 1
    done = (next_balance_check$max_o_diff < tolerance &
              next_balance_check$max_d_diff < tolerance) |
      i > max_iter
    
  }
  
  flows <- flows |>
    dplyr::mutate(flow = round(flow)) |>
    dplyr::select(o_id, d_id, flow)
  
  list(flows = flows, convergence = balance_check)
}

grvty_calibrate <- function(obs_flow_tt,
                            o_id_col,
                            d_id_col,
                            obs_flow_col,
                            tt_col,
                            tolerance_balancing,
                            max_iter_balancing,
                            tolerance_calibration,
                            max_iter_calibration) {
  
  # rename and select columns
  wip_flows <- obs_flow_tt |>
    dplyr::rename(o_id = tidyselect::all_of(o_id_col),
                  d_id = tidyselect::all_of(d_id_col),
                  flow = tidyselect::all_of(obs_flow_col),
                  tt = tidyselect::all_of(tt_col)) |>
    dplyr::select(o_id, d_id, flow, tt)
  
  # calculate average observed travel time
  mean_tt_obs <- sum(wip_flows$flow * wip_flows$tt) / 
    sum(wip_flows$flow)
  
  # calculate zone total origins and destinations
  zone_total_o <- wip_flows |>
    group_by(o_id) |>
    summarise(o = sum(flow)) |>
    rename(id = o_id)
  
  zone_total_d <- wip_flows |>
    group_by(d_id) |>
    summarize(d = sum(flow)) |>
    rename(id = d_id)
  
  zone_totals <- full_join(zone_total_o,
                           zone_total_d,
                           by = join_by(id)) |>
    replace_na(list(o = 0, d = 0))
  
  # balance origins and destinations if necessary
  if (sum(zone_totals$o) != sum(zone_totals$d)) {
    warning(paste0("Total number of origins does not equal total number of destinations.\n",
                   "Rescaling destinations for consistency with total origins.\n"))
    zone_totals$d = zone_totals$d *
      (sum(zone_totals$o)/sum(zone_totals$d))
  }
  
  # Calculate initial beta value
  m <- 1
  message(paste0("\nCalibration iteration ", m))
  
  beta_1 <- 1/mean_tt_obs
  
  # calculate initial friction factors
  wip_flows <- wip_flows |>
    mutate(friction = exp(-1 * beta_1 * tt))
  
  # initial flow estimates
  flows_result <- grvty_balancing(od_zones = zone_totals,
                                  friction = wip_flows,
                                  zone_id = "id",
                                  zone_o = "o",
                                  zone_d = "d",
                                  friction_o_id = "o_id",
                                  friction_d_id = "d_id",
                                  friction_factor = "friction",
                                  tolerance = tolerance_balancing,
                                  max_iter = max_iter_balancing)
  
  convergence <- flows_result$convergence
  
  if(nrow(convergence) >= max_iter_balancing) {
    warning(paste0("\nCalibration iteration ",
                   m,
                   ": Gravity model not balanced to required tolerance within maximum iterations.\n"))
  }
  
  flow_est <- flows_result$flows |>
    rename(flow_est = flow)
  
  flow_check <- wip_flows |>
    full_join(flow_est) |>
    replace_na(list(flow = 0,
                    flow_est = 0)) |>
    filter(!is.na(tt))
  
  # Check if average travel times are within tolerance
  mean_tt_est_1 <- sum(flow_check$flow_est * flow_check$tt) / 
    sum(flow_check$flow_est)
  
  if(abs(mean_tt_obs - mean_tt_est_1) < tolerance_calibration) {
    return(list(flows = flow_check, beta = beta_1, iterations = 1))
  }
  
  # move to iteration 2
  m <- 2
  message(paste0("\nCalibration iteration ", m))
  
  beta_2 <- beta_1 * mean_tt_est_1 / mean_tt_obs
  
  # calculate new friction factors
  wip_flows <- wip_flows |>
    mutate(friction = exp(-1 * beta_2 * tt)) 
  
  # recalculate trip matrix
  flow_result <- grvty_balancing(od_zones = zone_totals,
                                 friction = wip_flows,
                                 zone_id = "id",
                                 zone_o = "o",
                                 zone_d = "d",
                                 friction_o_id = "o_id",
                                 friction_d_id = "d_id",
                                 friction_factor = "friction",
                                 tolerance = tolerance_balancing,
                                 max_iter = max_iter_balancing)
  
  convergence <- flows_result$convergence
  
  if(nrow(convergence) >= max_iter_balancing) {
    warning(paste0("Calibration iteration ",
                   m,
                   ": Gravity model not balanced to required tolerance within maximum iterations.\n"))
  }
  
  flow_est <- flow_result$flows |>
    rename(flow_est = flow)
  
  flow_check <- wip_flows |>
    full_join(flow_est, by = join_by(o_id, d_id)) |>
    replace_na(list(flow = 0,
                    flow_est = 0)) |>
    filter(!is.na(tt))
  
  # Check if average travel times are within tolerance
  mean_tt_est_2 <- sum(flow_check$flow_est * flow_check$tt) / 
    sum(flow_check$flow_est)
  
  if(abs(mean_tt_obs - mean_tt_est_2) < tolerance_calibration) {
    return(list(flows = flow_check, beta = beta_2, iterations = 2))
  }
  
  # move to iteration 3
  m <- 3
  betas <- c(beta_1, beta_2)
  mean_tt_ests <- c(mean_tt_est_1, mean_tt_est_2)
  done <- FALSE
  
  while (!done) {
    
    betas[m] <- ((mean_tt_obs - mean_tt_ests[m-2])*betas[m-1] - (mean_tt_obs - mean_tt_ests[m-1])*betas[m-2]) /
      (mean_tt_ests[m-1] - mean_tt_ests[m-2])
    
    # calculate new friction factors
    wip_flows <- wip_flows |>
      mutate(friction = exp(-1 * betas[m] * tt))
    
    flow_result <- grvty_balancing(od_zones = zone_totals,
                                   friction = wip_flows,
                                   zone_id = "id",
                                   zone_o = "o",
                                   zone_d = "d",
                                   friction_o_id = "o_id",
                                   friction_d_id = "d_id",
                                   friction_factor = "friction",
                                   tolerance = tolerance_balancing,
                                   max_iter = max_iter_balancing)
    
    convergence <- flows_result$convergence
    
    if(nrow(convergence) >= max_iter_balancing) {
      warning(paste0("Calibration iteration ",
                     m,
                     ": Gravity model not balanced to required tolerance within maximum iterations.\n"))
    }
    
    flow_est <- flow_result$flows |>
      rename(flow_est = flow)
    
    flow_check <- wip_flows |>
      full_join(flow_est, by = join_by(o_id, d_id)) |>
      replace_na(list(flow = 0,
                      flow_est = 0)) |>
      filter(!is.na(tt))
    
    # Check if average travel times are within tolerance
    mean_tt_ests[m] <- sum(flow_check$flow_est * flow_check$tt) / 
      sum(flow_check$flow_est)
    
    if(abs(mean_tt_obs - mean_tt_ests[m]) < tolerance_calibration) {
      return(list(flows = flow_check, beta = betas[m], iterations = m))
      done = TRUE
    }
    if(m >= max_iter_calibration) {
      return(list(flows = flow_check, beta = betas[m], iterations = m))
      done = TRUE
    }
    m <- m+1
  }
  
}