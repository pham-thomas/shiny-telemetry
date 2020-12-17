##%######################################################%##
#                                                          #
####      Survival Analysis for Shiny      ####
#                                                          #
##%######################################################%##
# Author: Tom Pham
# Script and data info: This script performs survival analysis using CJS model
# and outputs both reach per 10km and cumulative estimates to csv for use in
# the Shiny app
# Data source: Data extracted from NOAA ERDDAP data server (oceanview)

library(RMark)
library(tidyverse)
library(rerddap)
library(lubridate)
library(clusterPower)
library(cowplot)
library(leaflet)


### Load TaggedFish and ReceiverDeployments tables through ERDDAP ---------------------------------------------------------------------

my_url <- "https://oceanview.pfeg.noaa.gov/erddap/"
JSATSinfo <- info('FED_JSATS_taggedfish', url = my_url)
TaggedFish <- tabledap(JSATSinfo, url = my_url)  

JSATSinfo <- info('FED_JSATS_receivers', url = my_url)
ReceiverDeployments <- tabledap(JSATSinfo, url = my_url)

# Establish ERDDAP url and database name
my_url <- "https://oceanview.pfeg.noaa.gov/erddap/"
JSATSinfo <- info('FED_JSATS_detects', url = my_url)

# Retrieve list of all studyIDs on FED_JSATS
studyid_list <- tabledap(JSATSinfo,
                         fields = c('study_id'),
                         url = my_url,
                         distinct = TRUE
) %>% 
  filter(study_id != "2017_BeaconTag") %>% 
  pull(study_id)


# Load functions ----------------------------------------------------------

get_detections <- function(studyID) {
  # Retrieve detection data from ERDDAP
  #
  # Arguments:
  #  studyID: StudyID name to retrieve data for
  #     
  # Return:
  #  df of detection data formatted correctly, add in RKM, Region, Lat, Lon, 
  # Release RKM, Release Lat, Release Lon, format types, rename cols
  
  df <- tabledap(JSATSinfo,
                 fields = c('study_id', 'fish_id', 'receiver_general_location',
                            'time'),
                 paste0('study_id=', '"',studyID, '"'),
                 url = my_url,
                 distinct = T
  ) %>% 
    left_join(
      ReceiverDeployments %>% 
        select(receiver_general_location, receiver_general_river_km, receiver_region,
               receiver_general_latitude, receiver_general_longitude)
    ) %>% 
    left_join(
      TaggedFish %>% 
        select(fish_id, release_river_km, release_latitude, release_longitude, 
               release_location) %>% distinct()
    )
  
  # Rename columns and change column types as ERDDAP returns data all in 
  # character format
  df <- df %>% 
    rename(
      StudyID = study_id,
      FishID = fish_id,
      GEN = receiver_general_location,
      GenRKM = receiver_general_river_km,
      Region = receiver_region,
      GenLat = receiver_general_latitude,
      GenLon =receiver_general_longitude,
      RelRKM = release_river_km,
      Rel_loc = release_location
    ) %>% 
    mutate(
      GenLat = ifelse(is.na(GenLat), release_latitude, GenLat),
      GenLon = ifelse(is.na(GenLon), release_longitude, GenLon),
      GenLat = as.numeric(GenLat),
      GenLon = as.numeric(GenLon),
      GenRKM = as.numeric(GenRKM),
      RelRKM = as.numeric(RelRKM),
      time = ymd_hms(time),
      GenRKM = ifelse(is.na(GenRKM), RelRKM, GenRKM)
    )
  
  # ERDDAP by default returns a table.dap object which does not play nice with
  # maggittr (pipes) so convert to tibble
  as_tibble(df)
  
}

# get_GEN_locs <- function(detections){
#   detections %>% 
#     select(StudyID, GEN, GenRKM) %>% 
#     distinct() %>% 
#     arrange(desc(GenRKM))
# }
# 
# all_GEN_locs <- lapply(all_detections, get_GEN_locs)

aggregate_GEN <- function(detections) {
  # Replace GEN in detections df according to replacelist
  #
  # Arguments:
  #  detections: a detections df
  #     
  # Return:
  #  a detections df that has replaced list of GEN with the aggregated GEN,
  #  mean RKM, mean Lat, mean Lon. Creates reach.meta.aggregate which is the list
  #  of receiver sites with new aggregated GEN's, along with RKM, Lat, Lon
  
  # Make a copy of reach.meta (receiver metadata)
  reach.meta.aggregate <<- reach.meta
  
  # Walk through each key/pair value
  for (i in 1:length(replace_dict$replace_with)) {
    # Unlist for easier to use format
    replace_list <- unlist(replace_dict[[2]][i])
    replace_with <- unlist(replace_dict[[1]][i])
    
    # Gather receiver data for the replace_list and replace, get the mean genrkm. 
    # This will be used to replace in the detections
    replace <- reach.meta %>% 
      select(GEN, GenRKM, GenLat, GenLon, Region) %>% 
      filter(GEN %in% c(replace_list, replace_with)) %>%
      distinct() %>% 
      select(-GEN) %>% 
      group_by(Region) %>% 
      summarise_all(mean)
    
    # Replace replace_list GENs name with replace_with GEN, and replace all of 
    # their genrkm with the averaged val
    detections <- detections %>% 
      mutate(
        GEN = ifelse(GEN %in% replace_list, replace_with, GEN),
        GenRKM = ifelse(GEN %in% c(replace_list, replace_with), replace$GenRKM, GenRKM),
        GenLat = ifelse(GEN %in% c(replace_list, replace_with), replace$GenLat, GenLat),
        GenLon = ifelse(GEN %in% c(replace_list, replace_with), replace$GenLon, GenLon),
      )
    
    # This new df shows receiver metadata and reflects the aggregation done
    reach.meta.aggregate <<- reach.meta.aggregate %>% 
      mutate(
        GEN = ifelse(GEN %in% replace_list, replace_with, GEN),
        GenRKM = ifelse(GEN %in% c(replace_list, replace_with), replace$GenRKM, GenRKM),
        GenLat = ifelse(GEN %in% c(replace_list, replace_with), replace$GenLat, GenLat),
        GenLon = ifelse(GEN %in% c(replace_list, replace_with), replace$GenLon, GenLon),
        Region = ifelse(GEN == "End", "End", ifelse(GEN %in% c(replace_list, replace_with), replace$Region, Region))
      ) %>% 
      distinct()
  }
  detections
}


make_EH <- function(detections) {
  # Make an encounter history df
  #
  # Arguments:
  #  detections: a detections df
  #     
  # Return:
  #  Encounter history df. A matrix of every fish tagged for a given studyID
  #  at every given receiver site (that is in reach.meta.aggregate) and whether
  #  it was present 1 or absent 0 in the detection df
  
  # Get earliest detection for each fish at each GEN
  min_detects <- detections %>% 
    filter(GEN %in% reach.meta.aggregate$GEN) %>% 
    group_by(FishID, GEN, GenRKM) %>% 
    summarise(
      min_time = min(time)
    ) %>% 
    arrange(
      FishID, min_time
    )
  
  # Get list of all tagged fish for the studyID
  fish <- TaggedFish %>% 
    filter(study_id == detections$StudyID[1]) %>% 
    arrange(fish_id) %>% 
    pull(fish_id)
  
  # Create matrix of all combinations of fish and GEN
  EH <- expand.grid(
    fish,
    reach.meta.aggregate$GEN, stringsAsFactors = FALSE 
  )
  
  names(EH) <- c('FishID', 'GEN')  
  
  # Add col detect to min_detects, these fish get a 1
  min_detects$detect <- 1
  
  # Join in detections to the matrix, fish detected a GEN will be given a 1
  # otherwise it will be given a 0
  EH <- EH %>% 
    left_join(
      min_detects %>% 
        select(
          FishID, GEN, detect
        ), by = c("FishID", "GEN")
    ) %>% 
    # Replace NA with 0 https://stackoverflow.com/questions/28992362/dplyr-join-define-na-values
    mutate_if(
      is.numeric, coalesce, 0
    )
  
  # Reshape the df wide, so that columns are GEN locations, rows are fish, 
  # values are 1 or 0 for presence/absence
  EH <- reshape(EH, idvar = 'FishID', timevar = 'GEN', direction = 'wide')
  colnames(EH) <- gsub('detect.', '', colnames(EH))
  # Manually make the release column a 1 because all fish were released there
  # sometimes detections df does not reflect that accurately
  EH[2] <- 1
  EH
}

create_inp <- function(detections, EH) { 
  # Create an inp df
  #
  # Arguments:
  #  detections: a detections df
  #  EH: an encounter history df
  #     
  # Return:
  #  inp df i.e. Fish01 | 11101, a record of a fish and it's presence/absence
  #  at each given receiver location. 
  
  EH.inp <- EH %>% 
    # Collapse the encounter columns into a single column of 1's and 0's
    unite("ch", 2:(length(EH)), sep ="") %>% 
    # Use the detections df to get the StudyID assignment
    mutate(StudyID = unique(detections$StudyID))
  EH.inp
}


get.mark.model <- function(all.inp, standardized, multiple) {
  # Run a CJS Mark model
  #
  # Arguments:
  #  all.inp: inp df, can be more than one studyID
  #  standardized: TRUE or FALSE, if you want outputs to be standardized to 
  #     per10km or not
  #  mutliple: TRUE or FALSE, if you have multiple studyIDs or not   
  #
  # Return:
  #  the outputs of running a CJS Mark model, df with phi and p estimates, LCI
  #  UCI, SE
  
  # For single studyID
  if (multiple == F) {
    # If standardized, set time.intervals to reach_length to get per 10km
    if (standardized) {
      KM <- reach.meta.aggregate$GenRKM
      reach_length <- abs(diff(KM))/10
      
      all.process <- process.data(all.inp, model="CJS", begin.time=1, 
                                  time.intervals = reach_length)
    } else {
      all.process <- process.data(all.inp, model="CJS", begin.time=1)
    }
    # For multiple studyID
  } else {
    # If multiple studyIDs, set groups to "StudyID
    if (standardized) {
      all.process <- process.data(all.inp, model="CJS", begin.time=1, 
                                  time.intervals = reach_length, groups = "StudyID")
    } else {
      all.process <- process.data(all.inp, model="CJS", begin.time=1,
                                  groups = "StudyID")
    }
  }
  
  
  all.ddl <- make.design.data(all.process)
  rm(list=ls(pattern="p.t.x.y"))
  rm(list=ls(pattern="Phi.t.x.y"))
  
  if (multiple) {
    p.t.x.y <- list(formula= ~time*StudyID)
    Phi.t.x.y <- list(formula= ~time*StudyID)
  }else {
    p.t.x.y <- list(formula= ~time)
    Phi.t.x.y <- list(formula= ~time)
  }
  
  cml = create.model.list("CJS")
  model.outputs <- mark.wrapper(cml, data=all.process, ddl=all.ddl) 
  outputs <- model.outputs$Phi.t.x.y.p.t.x.y$results$real
  
}

get_cum_survival <- function(all.inp, add_release) {
  # Run a CJS Mark model for cumulative survival
  #
  # Arguments:
  #  all.inp: inp df, can be more than one studyID
  #  add_release: TRUE or FALSE, if you wish to add an extra dummy row at the top
  #  to show 100% survival at the release location
  #
  # Return:
  #  Cumulative survival outputs of CJS Mark model
  
  all.process <- process.data(all.inp, model = "CJS", begin.time = 1)
  all.ddl <- make.design.data(all.process)
  
  rm(list=ls(pattern="Phi.t"))
  rm(list=ls(pattern="p.t"))
  
  p.t <- list(formula= ~time) 
  Phi.t <- list(formula= ~time)
  
  cml = create.model.list("CJS")
  
  model.outputs <- mark.wrapper(cml, data=all.process, ddl=all.ddl, realvcv = TRUE)
  
  reaches <- nchar(all.inp$ch[1]) - 1
  
  phi.t <- model.outputs$Phi.t.p.t$results$real$estimate[1:reaches] 
  phi.t.vcv <- model.outputs$Phi.t.p.t$results$real.vcv
  
  cum.phi <- cumprod(phi.t)
  
  # calculate standard errors for the cumulative product. 
  cum.phi.se <- deltamethod.special("cumprod", phi.t[1:reaches], 
                                    phi.t.vcv[1:(reaches),1:(reaches)])
  
  
  ### Output estimate, SE, LCI, UCI to a dataframe
  cumulative <- data.frame(cum.phi = cum.phi, cum.phi.se = cum.phi.se, 
                           LCI = expit(logit(cum.phi)-1.96*sqrt(cum.phi.se^2/((exp(logit(cum.phi))/(1+exp(logit(cum.phi)))^2)^2))),
                           UCI = expit(logit(cum.phi)+1.96*sqrt(cum.phi.se^2/((exp(logit(cum.phi))/(1+exp(logit(cum.phi)))^2)^2))))
  
  # Round to 3 digits
  cumulative <- round(cumulative,3)
  
  # If add_release TRUE, add in the dummy row to the top which just represents
  # survival of 100% at release
  if (add_release == T) {
    cumulative <- cumulative %>% 
      add_row(
        .before = 1,
        cum.phi = 1,
        cum.phi.se = NA,
        LCI = NA, 
        UCI = NA
      ) %>% 
      mutate(
        StudyID = all.inp$StudyID[1]
      )
  }else {
    cumulative <- cumulative %>% 
      mutate(
        StudyID = all.inp$StudyID[1]
      )
  }
  
}

get.receiver.GEN <- function(all_detections) {
  # Get a list of all receiver sites and metadata for a given detections df
  #
  # Arguments:
  #  all_detections: detections df 
  #
  # Return:
  #  df of receiver sites along with RKM, Lat, Lon, Region
  
  reach.meta <- all_detections %>% 
    bind_rows() %>% 
    distinct(GEN, GenRKM, GenLat, GenLon, Region) %>% 
    # Necessary because detections files shows differing RKM, Lat, Lon for some 
    # GEN sometimes
    group_by(GEN) %>% 
    summarise(
      GenRKM = mean(GenRKM),
      GenLat = mean(GenLat),
      GenLon = mean(GenLon),
      Region = first(Region)
    ) %>% 
    arrange(desc(GenRKM))
}


format.p <- function(output, multiple){
  # Format p outputs for plotting and table outputs
  #
  # Arguments:
  #  output: output df from Mark model
  #  mutliple: TRUE/FALSE if there were multiple StudyIDs in the outputs
  #
  # Return:
  #  properly formatted df for p outputs, now ready to plot
  
  # Format for single
  if (multiple == F) {
    outputs %>%
      slice(
        # Grab bottom half of outputs which are the p values
        ((nrow(outputs)/2) +1):nrow(outputs)
      ) %>%
      select(
        -c("fixed", "note")
      ) %>%
      # Add in some metadata so values make more sense
      add_column(
        reach_start = reach.meta.aggregate$GEN[1:(length(reach.meta.aggregate$GEN)-1)],
        reach_end = reach.meta.aggregate$GEN[2:(length(reach.meta.aggregate$GEN))],
        rkm_start = reach.meta.aggregate$GenRKM[1:(length(reach.meta.aggregate$GenRKM)-1)],
        rkm_end = reach.meta.aggregate$GenRKM[2:(length(reach.meta.aggregate$GenRKM))]
      ) %>% 
      mutate(
        Reach = paste0(reach_start, " to \n", reach_end),
        RKM = paste0(rkm_start, " to ", rkm_end),
      ) %>% 
      left_join(
        reach.meta.aggregate %>%
          select(GEN, Region) %>%
          distinct(),
        by = c("reach_start" = "GEN")
      ) %>% 
      mutate(reach_num = 1:n())
  } else {
    # If there are multiple StudyIDs, formatting is same idea just slightly 
    # different
    outputs %>%
      slice(
        ((nrow(outputs)/2) +1):nrow(outputs)
      ) %>%
      select(
        -c("fixed", "note")
      ) %>%
      rownames_to_column(var = "StudyID") %>%
      add_column(
        reach_start = rep(reach.meta.aggregate$GEN[1:(length(reach.meta.aggregate$GEN)-1)], 2),
        reach_end = rep(reach.meta.aggregate$GEN[2:(length(reach.meta.aggregate$GEN))], 2),
        rkm_start = rep(reach.meta.aggregate$GenRKM[1:(length(reach.meta.aggregate$GenRKM)-1)], 2),
        rkm_end = rep(reach.meta.aggregate$GenRKM[2:(length(reach.meta.aggregate$GenRKM))], 2)
      ) %>% 
      mutate(
        Reach = paste0(reach_start, " to \n", reach_end),
        RKM = paste0(rkm_start, " to ", rkm_end),
        reach_num = rep(1:(n()/2), 2)
      ) %>% 
      left_join(
        reach.meta.aggregate %>%
          select(GEN, Region) %>%
          distinct(),
        by = c("reach_start" = "GEN")
      ) %>% 
      rowwise() %>%
      mutate(
        StudyID = strsplit(strsplit(StudyID, "p g")[[1]][2], " ")[[1]][1]
      )
  }
}

format_phi <- function(outputs, multiple) {
  # Format phi outputs for plotting and table outputs
  #
  # Arguments:
  #  output: output df from Mark model
  #  mutliple: TRUE/FALSE if there were multiple StudyIDs in the outputs
  #
  # Return:
  #  properly formatted df for phi outputs, now ready to plot
  
  # Format for single
  if (multiple == F) {
    outputs %>%
      # Grab first half of Mark outputs which represent Phi values
      slice(1:(nrow(outputs) / 2)) %>%
      select(
        -c("fixed", "note")
      ) %>% 
      add_column(
        StudyID = studyID,
        reach_start = reach.meta.aggregate$GEN[1:(length(reach.meta.aggregate$GEN)-1)],
        reach_end = reach.meta.aggregate$GEN[2:(length(reach.meta.aggregate$GEN))],
        rkm_start = reach.meta.aggregate$GenRKM[1:(length(reach.meta.aggregate$GenRKM)-1)],
        rkm_end = reach.meta.aggregate$GenRKM[2:(length(reach.meta.aggregate$GenRKM))]
      ) %>% 
      left_join(
        reach.meta.aggregate %>%
          select(GEN, Region) %>%
          distinct(),
        by = c("reach_start" = "GEN")
      ) %>% 
      mutate(
        Reach = paste0(reach_start, " to \n", reach_end),
        RKM = paste0(rkm_start, " to ", rkm_end),
        reach_num = 1:n()
      ) 
  } else {
    outputs %>%
      slice(1:(nrow(outputs) / 2)) %>%
      select(
        -c("fixed", "note")
      ) %>% 
      rownames_to_column(var = "StudyID") %>%
      add_column(
        reach_start = rep(reach.meta.aggregate$GEN[1:(length(reach.meta.aggregate$GEN)-1)], 2),
        reach_end = rep(reach.meta.aggregate$GEN[2:(length(reach.meta.aggregate$GEN))], 2),
        rkm_start = rep(reach.meta.aggregate$GenRKM[1:(length(reach.meta.aggregate$GenRKM)-1)], 2),
        rkm_end = rep(reach.meta.aggregate$GenRKM[2:(length(reach.meta.aggregate$GenRKM))], 2),
        reach_num = rep(1:(nrow(reach.meta.aggregate)-1),length(all_EH))
      ) %>% 
      left_join(
        reach.meta.aggregate %>%
          select(GEN, Region) %>%
          distinct(),
        by = c("reach_start" = "GEN")
      ) %>% 
      mutate(
        Reach = paste0(reach_start, " to \n", reach_end),
        RKM = paste0(rkm_start, " to ", rkm_end)
      ) %>% 
      rowwise() %>%
      mutate(
        StudyID = strsplit(strsplit(StudyID, "Phi g")[[1]][2], " ")[[1]][1]
      )
  }
  
}

get.unique.detects <- function(all_aggregated){
  # Get raw number of unique fish detected at each GEN 
  #
  # Arguments:
  #  all_aggregated: df of detections that have been replaced with aggregating
  #  receiver locations
  #
  # Return:
  #  df of each GEN in a detections df and the raw number of unique fish detected
  
  all_aggregated %>% 
    bind_rows() %>% 
    select(StudyID, FishID, GEN, GenRKM) %>% 
    distinct() %>% 
    group_by(StudyID, GEN, GenRKM) %>% 
    summarise(
      count = n()
    ) %>% 
    arrange(StudyID, desc(GenRKM)) %>% 
    ungroup()
}

plot.phi <- function(phi, type, add_breaks, ylabel, xlabel, multiple, 
                     padding = 5.5) {
  # Plot phi outputs from Mark model
  #
  # Arguments:
  #  phi: phi outputs from Mark model, must be formatted with (format_phi) first
  #  type: "Reach" or "Region", dictates how the plot will be created
  #  add_breaks: TRUE/FALSE whether to add vertical line breaks to represent
  #     regions
  #  ylabel: label for y axis
  #  xlabel: label for x axis
  #  multiple: TRUE/FALSE, whether there are multiple studyIDs or not
  #  padding: leftside plot margin, default set to 5.5 good for most, but can
  #     be adjusted of the xaxis label too long and gets cut off
  #
  # Return:
  #  plot of phi with estimate and error bars representing LCI, UCI
  
  # Create the levels order 
  lvls <- phi %>% select(type) %>% distinct() %>% pull()
  
  # # Unfortunately, this method of variable assignment doesn't work when I have
  # # Multiple studyIDs, something to do with recycling rules in mutate()
  # p <- phi %>%
  #   mutate(
  #     # !! allows me to select the column by the arg I pass (Reach or Region),
  #     # := goes in hand with assignment via !!
  #     # https://github.com/tidyverse/ggplot2/releases/tag/v3.0.0
  #     !!type := factor(lvls, levels = lvls)
  #   ) %>%
  #   filter(reach_end != "GoldenGateW")
  
  # Does same thing as above in base R
  p <- phi
  p[type] <- factor(rep(lvls, length(studyIDs)), levels = lvls)
  p <- p %>% 
    # Filter out the GGE to GGW estimate, not really useful
    filter(reach_end != "GoldenGateW")
  
  if (type == "Reach") {
    # If plotting for Reach survival set angle of xaxis to be 45 degrees because
    # they are too long
    angle <- 45
    hjust <- 1
  }else {
    angle <- 0
    hjust <- 0.5
  }
  
  if (multiple == T) {
    ggplot(data = p, mapping = aes(x = get(type), y = estimate, group = StudyID)) +
      geom_point(aes(color = StudyID), position = position_dodge(.5)) +
      geom_errorbar(mapping = aes(x = get(type), ymin = lcl, ymax = ucl, 
                                  color = StudyID),  width = .1,
                    position = position_dodge(.5)) +
      # Conditionally add breaks 
      {if(add_breaks)geom_vline(xintercept = region_breaks, linetype = "dotted")} +
      ylab(ylabel) +
      xlab(xlabel) +
      ## WILL NEED TO FIX THIS, ONLY WORKS FOR 2 STUDYIDS
      scale_color_manual(values=c("#007EFF", "#FF8100")) +
      theme_classic() +
      theme(
        panel.border = element_rect(colour = "black", fill=NA, size=.75),
        axis.text.x = element_text(angle = angle, hjust = hjust),
        plot.margin = margin(5.5, 5.5, 5.5, padding, "pt"),
        legend.position = c(.12 ,.9)
      )
    
  }  else {
    ggplot(data = p, mapping = aes(x = get(type), y = estimate)) +
      geom_point() +
      geom_errorbar(mapping = aes(x= get(type), ymin = lcl, ymax = ucl), 
                    width = .1) +
      # Conditionally add breaks 
      {if(add_breaks)geom_vline(xintercept = region_breaks, linetype = "dotted")} +
      ylab(ylabel) +
      xlab(xlabel) +
      theme_classic() +
      theme(
        panel.border = element_rect(colour = "black", fill=NA, size=.75),
        axis.text.x = element_text(angle = angle, hjust = hjust)
      )
  }
}

make.phi.table <- function(phi, standardized = T) {
  # Format phi outputs further to be ready to save as a csv
  #
  # Arguments:
  #  phi: phi outputs from Mark model, must be formatted with (format_phi) first
  #
  # Return:
  #  phi df formatted the way I want to be saved as csv
  ifelse(standardized, label <-  'Survival rate per 10km (SE)',
         label <- 'Survival rate (SE)')
  
  phi %>% 
    select(StudyID, reach_num, Reach, RKM, Region, Estimate = estimate, SE = se, 
           LCI = lcl, UCI = ucl, N= count) %>% 
    mutate(
      Reach = str_remove_all(Reach, "\n"),
      Estimate = round(Estimate, 2),
      SE = round(SE, 2),
      LCI = round(LCI, 2),
      UCI = round(UCI, 2),
      Estimate2 = paste0(Estimate, " (", as.character(SE), ")")
    ) %>% 
    rename(!!label := Estimate2,
           'Reach #' = reach_num)
}

plot.p <- function(p, multiple) {
  # Plot p outputs from Mark model
  #
  # Arguments:
  #  p: p outputs from Mark model, must be formatted with (format.p) first
  #  multiple: T if multiple studyIDs, F is single
  #
  # Return:
  #  plot of p with estimate and error bars representing LCI, UCI
  if (multiple == F) {
    p %>% 
      mutate(
        Reach = factor(reach_num, levels = p$reach_num)
      ) %>% 
      ggplot(mapping = aes(x = reach_num, y = estimate)) +
      geom_point() +
      geom_errorbar(mapping = aes(ymin = lcl, ymax = ucl)) +
      ylab("Detection probability") +
      xlab("Reach") +
      scale_x_continuous(breaks = p$reach_num) +
      theme_classic() +
      theme(
        panel.border = element_rect(colour = "black", fill=NA, size=.75),
      )
  } else { # If multiple studyIDs
    
    # Create the levels order 
    lvls <- p %>% select(reach_num) %>% distinct() %>% pull()
    
    p %>% 
      mutate(
        Reach = factor(reach_num, levels = lvls)
      ) %>% 
      ggplot(mapping = aes(x = reach_num, y = estimate, group = StudyID)) +
      geom_point(aes(color = StudyID), position = position_dodge(.6)) +
      geom_errorbar(mapping = aes(x = reach_num, ymin = lcl, ymax = ucl, 
                                  color = StudyID),  width = .1,
                    position = position_dodge(.6)) +      
      ylab("Detection probability") +
      xlab("Reach") +
      scale_x_continuous(breaks = lvls) +
      theme_classic() +
      theme(
        panel.border = element_rect(colour = "black", fill=NA, size=.75),
      )
  }
  
}

format.cum.surv <- function(cum_survival_all) {
  # Format cumulative survival outputs for plotting and table outputs
  #
  # Arguments:
  #  cum_survival_all: output df from Mark model cumulative survival
  #
  # Return:
  #  properly formatted df for phi outputs, now ready to plot
  
  cum_survival_all <- cum_survival_all %>% 
    add_column(
      GEN = rep(reach.meta.aggregate$GEN[1:(length(reach.meta.aggregate$GEN))], 
                length(studyID)),
      RKM = rep(reach.meta.aggregate$GenRKM[1:(length(reach.meta.aggregate$GenRKM))], 
                length(studyID)),
      reach_num = rep(seq(0, (nrow(reach.meta.aggregate))-1, 1), length(studyID))
    ) %>% 
    left_join(
      reach.meta.aggregate %>%
        select(GEN, Region) %>% 
        distinct(),
      by = c("GEN")
    ) %>% 
    mutate(
      'Survival estimate (SE)' = paste0(cum.phi, " (", as.character(cum.phi.se), ")"),
      'Reach #' = reach_num
    ) %>% filter(
      GEN != "GoldenGateW"
    )
  
}

plot.cum.surv <- function(cum_survival_all, add_breaks, multiple, padding = 5.5) {
  # Plot cumulative survival outputs from Mark model
  #
  # Arguments:
  #  cum_survival_all: cumulative survival outputs from Mark model, 
  #     must be formatted with (format.cum.surv) first
  #  add_breaks: TRUE/FALSE whether to add vertical line breaks to represent
  #     regions
  #  multiple: TRUE/FALSE, whether there are multiple studyIDs or not
  #  padding: leftside plot margin, default set to 5.5 good for most, but can
  #     be adjusted of the xaxis label too long and gets cut off
  #
  # Return:
  #  plot of cumulative survival with estimate and error bars representing LCI, UCI
  
  if (multiple) {
    cum_survival_all %>% 
      mutate(
        GEN = factor(GEN, levels = reach.meta.aggregate$GEN,
                     labels = paste0(reach.meta.aggregate$GEN, " (", 
                                     reach.meta.aggregate$GenRKM, ")"))
      ) %>% 
      ggplot(mapping = aes(x = GEN, y = cum.phi, group = StudyID)) +
      geom_point(size = 2, aes(color = StudyID)) +
      geom_errorbar(mapping = aes(x= GEN, ymin = LCI, ymax = UCI, 
                                  color = StudyID),  width = .1) +
      geom_line(size = 0.7, aes(color = StudyID)) +
      {if(add_breaks)geom_vline(xintercept = region_breaks, linetype = "dotted")} +
      ylab("Cumulative survival") +
      xlab("Site (River KM)") +
      scale_y_continuous(breaks = seq(0, 1, 0.1)) +
      # NEEDS TO BE FIXED FOR IF THERE ARE MORE THEN 2 STUDYIDS
      scale_color_manual(values=c("#007EFF", "#FF8100")) +
      theme_classic() +
      theme(
        panel.border = element_rect(colour = "black", fill=NA, size=.5),
        axis.text.x = element_text(angle = 45, hjust = 1),
        plot.margin = margin(5.5, 5.5, 5.5, padding, "pt"),
        legend.position = c(.1 ,.12)
      ) 
  } else {
    cum_survival_all %>% 
      mutate(
        GEN = factor(GEN, levels = reach.meta.aggregate$GEN,
                     labels = paste0(reach.meta.aggregate$GEN, " (", 
                                     reach.meta.aggregate$GenRKM, ")"))
      ) %>% 
      ggplot(mapping = aes(x = GEN, y = cum.phi)) +
      geom_point(size = 2) +
      geom_errorbar(mapping = aes(x= GEN, ymin = LCI, ymax = UCI),  width = .1) +
      geom_line(size = 0.7, group = 1) +
      {if(add_breaks)geom_vline(xintercept = region_breaks, linetype = "dotted")} +
      ylab("Cumulative survival") +
      xlab("Site (River KM)") +
      scale_y_continuous(breaks = seq(0, 1, 0.1)) +
      theme_classic() +
      theme(
        panel.border = element_rect(colour = "black", fill=NA, size=.5),
        axis.text.x = element_text(angle = 45, hjust = 1),
        plot.margin=unit(c(.5,.5,.5,1), "cm"),
      ) 
  }
}


#### Output Reach Survival Per 10km ------------------------------------------
all_surv <- function(studyID) {
  
  print(studyID)
  
  output_inp <- function(studyID, replace_dict = list(replace_with = list(c("Chipps"),
                                                                          c("Benicia")),
                                                      replace_list = list(c("ChippsE", "ChippsW"),
                                                                          c("BeniciaE", "BeniciaW")))) {
    detections <- get_detections(studyID)
    
    reach.meta <- get.receiver.GEN(detections)
    
    # Remove Delta and Yolo sites except for Chipps
    reach.meta <- reach.meta %>% 
      filter(
        !Region %in% c("North Delta", "East Delta", "West Delta", "Yolo Bypass") |
          GEN %in% c("ChippsE", "ChippsW")
      )
    
    aggregated <- aggregate_GEN(detections)
    
    EH <- make_EH(aggregated)
    
    inp <- create_inp(aggregated, EH)
  }
  
  inp <- output_inp(studyID)
  reach_surv <- get.mark.model(inp, standardized = T, multiple = F)
  reach_surv <- format_phi(reach_surv, multiple = F) %>% 
    filter(reach_end != "GoldenGateW")
  
  write_csv(reach_surv, paste0(studyID, "_reach_survival_per10km.csv"))
  print(paste0(studyID, "_reach_survival_per10km.csv"))
  
  cum_surv <- get_cum_survival(inp, add_release = T)
  cum_surv <- format.cum.surv(cum_surv)
  
  write_csv(cum_surv, paste0(studyID, "_cumulative_survival.csv"))
  print(paste0(studyID, "_cumulative_survival.csv"))
  
  cleanup(ask = F)
  
}

for (i in studyid_list) {
  print(i)
  all__surv(i)
  print(paste0(i, "done"))
}






