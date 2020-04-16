library(rstan)
library(data.table)
library(lubridate)
library(gdata)
library(EnvStats) # For gammaAlt functions

## Code addapted to handle Western Pacific countries for WHO Regional 
## Office (WPRO). Additional comments added to translate methods from 
## Imperial report:
## * Seth Flaxman, Swapnil Mishra, Axel Gandy et al. Estimating the number 
## of infections and the impact of nonpharmaceutical interventions on 
## COVID-19 in 11 
## European countries. Imperial College London (30-03-2020)
## doi: https://doi.org/10.25561/77731.

# User Options ------------------------------------------------------------
countries <- c(
  "Philippines",
  "Malaysia" #,
  # "Laos"
)

options <- list("include_ncd" = FALSE,
  "npi_on" = FALSE,
  "fullRun" = FALSE,
  "debug" = FALSE)

args = commandArgs(trailingOnly=TRUE)
if(length(args) == 0) {
  args = 'base'
} 
StanModel = args[1]

print(sprintf("Running %s",StanModel))

## Reading all data -------------------------------------------------------
d=readRDS('data_wpro/COVID-19-up-to-date.rds')

## get IFR
ifr.by.country = read.csv("data_wpro/weighted_fatality.csv")
ifr.by.country$country = as.character(ifr.by.country[,1])
if (options$include_ncd) {
  ifr.by.country$weighted_fatality = ifr.by.country$weighted_fatality_NCD
} else {
  ifr.by.country$weighted_fatality = ifr.by.country$weighted_fatality_noNCD
}

if (length(countries) == 1) {
  ifr.by.country = ifr.by.country[ifr.by.country$country == countries[1],]
  ifr.by.country = rbind(ifr.by.country,ifr.by.country)
}

# Get serial interval
serial.interval = read.csv("data_wpro/serial_interval.csv") 
# Not sure why we serial interval instead of just specifying mean and cv below?? Maybe because it is discretized see page 19 of report. 
# dgammaAlt(100, 6.5, cv = 0.62)

# Start sorting out NPIs which are given by dates of start.
covariates = read.csv('data_wpro/interventions.csv', 
  stringsAsFactors = FALSE)
covariates <- covariates[1:length(countries), c(1,2,3,4,5,6, 7, 8)]

# If missing put far into future
covariates[is.na(covariates)] <- "31/12/2020" 

# Makes sure dates are right format
covariates[,2:8] <- lapply(covariates[,2:8], 
  function(x) as.Date(x, format='%d/%m/%Y'))

# Hack if only one country
if (length(countries) == 1) {
  covariates = covariates[covariates$Country == countries[1],]
  covariates = rbind(covariates,covariates)
}

## making all covariates that happen after lockdown to have same date as lockdown
covariates$schools_universities[covariates$schools_universities > covariates$lockdown] <- covariates$lockdown[covariates$schools_universities > covariates$lockdown]
covariates$travel_restrictions[covariates$travel_restrictions > covariates$lockdown] <- covariates$lockdown[covariates$travel_restrictions > covariates$lockdown]
covariates$public_events[covariates$public_events > covariates$lockdown] <- covariates$lockdown[covariates$public_events > covariates$lockdown]
covariates$sport[covariates$sport > covariates$lockdown] <- covariates$lockdown[covariates$sport > covariates$lockdown]
covariates$social_distancing_encouraged[covariates$social_distancing_encouraged > covariates$lockdown] <- covariates$lockdown[covariates$social_distancing_encouraged > covariates$lockdown]
covariates$self_isolating_if_ill[covariates$self_isolating_if_ill > covariates$lockdown] <- covariates$lockdown[covariates$self_isolating_if_ill > covariates$lockdown]

p <- ncol(covariates) - 1
forecast = 0

if(options$debug == FALSE) {
  N2 = 75 # Increase this for a further forecast
}  else  {
  ### For faster runs:
  # Restrict number of countries - don't need this at the moment. 
  N2 = 75
}

# Hack to handle one country
if (length(countries) == 1) {
  countries <- c(countries[1], countries[1])
}

# Initialize inputs ------------------------------------------------------
dates = list()
reported_cases = list()
stan_data = list(M=length(countries),N=NULL,p=p,
  x1=poly(1:N2,2)[,1], x2=poly(1:N2,2)[,2],
  y=NULL,covariate1=NULL,covariate2=NULL,covariate3=NULL,
  covariate4=NULL,covariate5=NULL,covariate6=NULL,covariate7=NULL,
  deaths=NULL,f=NULL,N0=6,cases=NULL,LENGTHSCALE=7,
  SI=serial.interval$fit[1:N2],
  EpidemicStart = NULL) # N0 = 6 to make it consistent with Rayleigh
deaths_by_country = list()

for(Country in countries) {
  IFR=ifr.by.country$weighted_fatality[ifr.by.country$country == Country]
  
  covariates1 <- covariates[covariates$Country == Country, 2:8]
  
  d1=d[d$Countries.and.territories==Country,]
  d1$date = as.Date(d1$DateRep,format='%d/%m/%Y')
  d1$t = decimal_date(d1$date) 
  d1=d1[order(d1$t),]
  
  # Sort out day of first case and day when 10 deaths are reached
  index = which(d1$Cases>0)[1]
  index1 = which(cumsum(d1$Deaths)>=10)[1] # also 5
  # Assumed day of seeding of new infections. See page 20 of report. 
  index2 = index1-30 
  
  print(sprintf(paste("First non-zero cases is on day %d, and 30 days", 
    "before 10 deaths is day %d"), index, index2))
  d1=d1[index2:nrow(d1),]
  stan_data$EpidemicStart = c(stan_data$EpidemicStart,index1+1-index2)
  
  # Specify covariate being on/off using 0, 1. Assume 1 on and after date 
  # of start
  for (ii in 1:ncol(covariates1)) {
    covariate = names(covariates1)[ii]
    d1[covariate] <- (as.Date(d1$DateRep, format='%d/%m/%Y') >= 
        as.Date(covariates1[1,covariate], format='%d/%m/%Y'))*1  
    # should this be > or >=?
  }
  
  dates[[Country]] = d1$date
  
  ## Hazard function and survival -----------------------------------------
  
  # Hazard estimation for death following infection
  # Gamma distributions for time to infection from onset and time from 
  # onset to death (see parameters below). 
  # Then multiply by IFR to get death probability.
  N = length(d1$Cases)
  print(sprintf("%s has %d days of data",Country,N))
  forecast = N2 - N # number of days to forecast?
  if(forecast < 0) {
    print(sprintf("%s: %d", Country, N))
    print("ERROR!!!! increasing N2")
    N2 = N
    forecast = N2 - N
  }
  
  h = rep(0, forecast + N) # discrete hazard rate from time t = 1, ..., 100
  
  if(options$debug) { 
    # OLD -- but faster for testing this part of the code
    mean = 18.8
    cv = 0.45
    
    for(i in 1:length(h))
      h[i] = (IFR*pgammaAlt(i,mean = mean,cv=cv) -
          IFR*pgammaAlt(i-1,mean = mean,cv=cv)) /
      (1-IFR*pgammaAlt(i-1,mean = mean,cv=cv))
    
  } else { 
    # Master 
    mean1 = 5.1; cv1 = 0.86; # infection to onset 
    mean2 = 18.8; cv2 = 0.45 # onset to death
    
    ## assume that IFR is probability of dying given infection us 
    ## gammaAlt functions from EnvStats package
    
    ## Infection to onset
    x1 = rgammaAlt(5e6, mean1, cv1) 
    # infection-to-onset ----> do all people who are infected get to onset?
    
    # RTG: I would say no because some would be asymptomatic? Should be 
    # reflected in IFR though?
    
    ## Onset to death
    x2 = rgammaAlt(5e6,mean2,cv2) 
    
    # Combined rate - time from infection to deaths door and then see if 
    # die with probability given by IFR
    f = ecdf(x1+x2)
    convolution = function(u) (IFR * f(u))
    
    # Discretized daily infection to death Distribution?? - 
    # see page 17-18 of report
    h[1] = (convolution(1.5) - convolution(0)) 
    for(i in 2:length(h)) {
      # I don't get this estimate for the integral??
      h[i] = (convolution(i+0.5) - convolution(i-0.5)) / 
        (1-convolution(i-0.5))
    }
  }
  
  # Set up survival curve.
  # Probablity of survival by day i is number of survivors by day i-1 times 
  # (1-hazard) of dying by day i-1.
  s = rep(0,N2)
  s[1] = 1 
  for(i in 2:N2) {
    s[i] = s[i-1]*(1-h[i-1]) 
  }
  # S = (1-h[1])*(1-h[2])*(1-h[3])*.....
  
  # Number of fatalities each day - survivors * hazard of death
  f = s * h 
  
  # Set-up country epi data and stan inputs -------------------------------
  y=c(as.vector(as.numeric(d1$Cases)),rep(-1,forecast))
  reported_cases[[Country]] = as.vector(as.numeric(d1$Cases))
  deaths=c(as.vector(as.numeric(d1$Deaths)),rep(-1,forecast))
  cases=c(as.vector(as.numeric(d1$Cases)),rep(-1,forecast))
  deaths_by_country[[Country]] = as.vector(as.numeric(d1$Deaths))
  
  # Extend covaraites to forecast days
  covariates2 <- as.data.frame(d1[, colnames(covariates1)])
  # x=1:(N+forecast)
  covariates2[N:(N+forecast),] <- covariates2[N,]
  
  ## Append data to forecast days into stan_data
  stan_data$N = c(stan_data$N,N)
  stan_data$y = c(stan_data$y,y[1]) # just the index case!
  # stan_data$x = cbind(stan_data$x,x)
  stan_data$covariate1 = cbind(stan_data$covariate1,covariates2[,1])
  stan_data$covariate2 = cbind(stan_data$covariate2,covariates2[,2])
  stan_data$covariate3 = cbind(stan_data$covariate3,covariates2[,3])
  stan_data$covariate4 = cbind(stan_data$covariate4,covariates2[,4])
  stan_data$covariate5 = cbind(stan_data$covariate5,covariates2[,5])
  stan_data$covariate6 = cbind(stan_data$covariate6,covariates2[,6])
  stan_data$covariate7 = cbind(stan_data$covariate7,covariates2[,7]) 
  stan_data$f = cbind(stan_data$f,f)
  stan_data$deaths = cbind(stan_data$deaths,deaths)
  stan_data$cases = cbind(stan_data$cases,cases)
  
  stan_data$N2=N2
  stan_data$x=1:N2
  if(length(stan_data$N) == 1) {
    stan_data$N = as.array(stan_data$N)
  }
}

if (options$npi_on) {
  ## Sort out covariates as models should only take 6 covariates
  ## Replace travel bans and sports with self-isolating and any intervention
  stan_data$covariate2 = 0 * stan_data$covariate2 # remove travel bans
  stan_data$covariate4 = 0 * stan_data$covariate5 # remove sport
  
  #stan_data$covariate1 = stan_data$covariate1 # school closure
  stan_data$covariate2 = stan_data$covariate7 # self-isolating if ill
  #stan_data$covariate3 = stan_data$covariate3 # public events
  # create the `any intervention` covariate
  stan_data$covariate4 = 1*as.data.frame((stan_data$covariate1+
      stan_data$covariate3+
      stan_data$covariate5+
      stan_data$covariate6+
      stan_data$covariate7) >= 1)
  stan_data$covariate5 = stan_data$covariate5 # lockdown
  stan_data$covariate6 = stan_data$covariate6 # social distancing encouraged
  stan_data$covariate7 = 0 # models should only take 6 covariates
} else {
  # Turn off NPIs
  stan_data$covariate1 = 0 * stan_data$covariate1
  stan_data$covariate2 = 0 * stan_data$covariate2
  stan_data$covariate3 = 0 * stan_data$covariate3
  stan_data$covariate4 = 0 * stan_data$covariate4
  stan_data$covariate5 = 0 * stan_data$covariate5
  stan_data$covariate6 = 0 * stan_data$covariate6
  stan_data$covariate7 = 0
}

# Check NPI dates
if(options$debug) {
  for(i in 1:length(countries)) {
    write.csv(
      data.frame(date=dates[[i]],
        `school closure`=stan_data$covariate1[1:stan_data$N[i],i],
        `self isolating if ill`=stan_data$covariate2[1:stan_data$N[i],i],
        `public events`=stan_data$covariate3[1:stan_data$N[i],i],
        `government makes any intervention`=stan_data$covariate4[1:stan_data$N[i],i],
        `lockdown`=stan_data$covariate5[1:stan_data$N[i],i],
        `social distancing encouraged`=stan_data$covariate6[1:stan_data$N[i],i]),
      file=sprintf("results/%s-check-dates.csv",countries[i]),row.names=F)
  }
}

# Set-up and run sampling -------------------------------------------------
stan_data$y = t(stan_data$y)
options(mc.cores = parallel::detectCores())
rstan_options(auto_write = TRUE)
m = stan_model(paste0('stan-models/',StanModel,'.stan'))

if(options$debug) {
  fit = sampling(m,data=stan_data,iter=40,warmup=20,chains=2)
} else { 
  if(options$fullRun) {
    fit = sampling(m,data=stan_data,iter=4000,warmup=2000,chains=8,thin=4,
      control = list(adapt_delta = 0.90, max_treedepth = 10))
  } else {
    fit = sampling(m,data=stan_data,iter=200,warmup=100,chains=4,thin=4,
      control = list(adapt_delta = 0.90, max_treedepth = 10))
  }
}  

# Extract outputs and save results ----------------------------------------
out = rstan::extract(fit)
prediction = out$prediction
estimated.deaths = out$E_deaths
estimated.deaths.cf = out$E_deaths0

JOBID = Sys.getenv("PBS_JOBID")
if(JOBID == "")
  JOBID = as.character(abs(round(rnorm(1) * 1000000)))
print(sprintf("Jobid = %s",JOBID))

save.image(paste0('results/',StanModel,'-',JOBID,'.Rdata'))

save(fit,out,prediction,dates,reported_cases,deaths_by_country,countries,
  estimated.deaths,estimated.deaths.cf,out,covariates,
  file=paste0('results/',StanModel,'-',JOBID,'-stanfit.Rdata'))

# Visualize results -------------------------------------------------------
# library(bayesplot)
filename <- paste0('base-',JOBID)
# plot_labels <- c("School Closure",
#   "Self Isolation",
#   "Public Events",
#   "First Intervention",
#   "Lockdown", 'Social distancing')
# alpha = (as.matrix(out$alpha))
# colnames(alpha) = plot_labels
# g = (mcmc_intervals(alpha, prob = .9))
# ggsave(sprintf("results/%s-covars-alpha-log.pdf",filename),g,width=4,
#   height=6)
# g = (mcmc_intervals(alpha, prob = .9,
#   transformations = function(x) exp(-x)))
# ggsave(sprintf("results/%s-covars-alpha.pdf",filename),g,width=4,height=6)
# mu = (as.matrix(out$mu))
# colnames(mu) = countries
# g = (mcmc_intervals(mu,prob = .9))
# ggsave(sprintf("results/%s-covars-mu.pdf",filename),g,width=4,height=6)
# dimensions <- dim(out$Rt)
# Rt = (as.matrix(out$Rt[,dimensions[2],]))
# colnames(Rt) = countries
# g = (mcmc_intervals(Rt,prob = .9))
# ggsave(sprintf("results/%s-covars-final-rt.pdf",filename),g,width=4,
#   height=6)


# system(paste0("Rscript plot-3-panel.r ", filename,'.Rdata'))
source("plot-3-panel.r")
summaryOutput <- make_three_panel_plot(paste0(filename,'.Rdata'))
for (ii in 1:length(countries)) {
  write.csv(summaryOutput[[ii]], paste0('figures/SummaryResults-',JOBID,
    '-',countries[[ii]],'.csv'))
}
# system(paste0("Rscript plot-forecast.r ",filename,'.Rdata')) ## to run this code you will need to adjust manual values of forecast required