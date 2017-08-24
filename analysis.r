# build fancy steam train plot from downloaded gapminder and berkeley earth data
# james goldie ('rensa'), august 2017

library(RCurl)
library(rvest)
library(tidyverse)
library(magrittr)
library(readxl)
library(stringr)
library(fuzzyjoin)
library(viridis)
library(gganimate)
library(tweenr)
filter = dplyr::filter # this is going to kill me one day

source('util.r')
if(!dir.exists('data'))
{
  dir.create('data')
}

# constants
on_url = 'https://raw.githubusercontent.com/open-numbers/'
giss_url = 'https://data.giss.nasa.gov/tmp/modelE/ltmap/'
berk_url = 'http://berkeleyearth.lbl.gov/auto/Regional/TAVG/Text/'
year_start = 1900
year_end = 2012

# download gapminder files if they haven't been downloaded before
gap_files = data_frame(
  repo = c(
    'ddf--gapminder--population',
    'ddf--cait--historical_emissions',
    'ddf--gapminder--gdp_per_capita_cppp',
    'ddf--gapminder--population',
    'ddf--cait--historical_emissions'),
  file = c(
    'ddf--entities--geo--country.csv',
    'ddf--entities--country.csv',
    'ddf--datapoints--gdp_per_capita_cppp--by--geo--time.csv',
    'ddf--datapoints--population--by--country--year.csv',
    paste0(
      'ddf--datapoints--total_co2_emissions_excluding_land_use_change_and_',
      'forestry_mtco2--by--country--year.csv')),
  url = paste0(on_url, repo, '/master/', file))
gap_files_to_download = which(!file.exists(paste0('data/', gap_files$file)))

if (length(gap_files_to_download) > 0)
{
  message(run.time(), ' downloading missing gapminder data')
  mapply(download.file,
    gap_files$url[which(!file.exists(paste0('data/', gap_files$file)))],
    destfile =
      paste0('data/', gap_files$file[which(!file.exists(gap_files$file))])) 
} else
{
  message(run.time(), ' found all gapminder data')
}

# load and tidy gapminder country equivalences
message(run.time(), ' loading and tidying any missing gapminder data')
geo_gap =
  read_csv('data/ddf--entities--geo--country.csv') %>%
  select(country, name)
geo_co2 =
  read_csv('data/ddf--entities--country.csv')

# download and tidy gapminder data sets
gdp_percap = 
  read_csv('data/ddf--datapoints--gdp_per_capita_cppp--by--geo--time.csv') %>%
  rename(country = geo, year = time, gdppc = gdp_per_capita_cppp) %>%
  filter(year >= year_start & year <= year_end) %>%
  inner_join(geo_gap) %>%
  select(name, year, gdppc)
pop =
  read_csv('data/ddf--datapoints--population--by--country--year.csv') %>%
  filter(year >= year_start & year <= year_end) %>%
  inner_join(geo_gap) %>%
  select(name, year, population)
co2 =
  read_csv(paste0(
    'data/ddf--datapoints--total_co2_emissions_excluding_land_use_change_','and_forestry_mtco2--by--country--year.csv')) %>%
  rename(
    co2 = total_co2_emissions_excluding_land_use_change_and_forestry_mtco2) %>%
  filter(year >= year_start & year <= year_end) %>%
  inner_join(geo_co2) %>%
  select(name, year, co2)

# combine gapminder datasets,
# rank countries each year by their gdp per capita
# claculation global pop, pop fraction and number of poorer people each year
message(run.time(), ' combining gapminder data')
gapdata = co2 %>%
  inner_join(gdp_percap, by = c('name', 'year')) %>%
  inner_join(pop, by = c('name', 'year')) %>%
  mutate(annual_devrank = ave(gdppc, year, FUN = rank)) %>%
  group_by(year) %>%
  arrange(annual_devrank) %>%
  mutate(
    pop_global = sum(population),
    pop_fraction = population / pop_global,
    pop_poorer = cumsum(population) - population,
    pop_poorer_fraction = pop_poorer / pop_global) %>%
  ungroup() %>%
  mutate(., emission_id = group_indices(., name, year))

# scrape a list of available berkeley earth country temp data files and
# match them fuzzily against gapdata countries
message(run.time(), ' scraping list of available berkeley temperature data')
berk_files =
  data_frame(
    filename = berk_url %>% read_html %>% html_nodes('a') %>% html_text) %>%
  slice(-(1:6)) %>%
  mutate(
    name_lowercase = str_replace(filename, '-TAVG-Trend.txt', '')) %>%
  # drop some tricky rows (utf escaping problems? TODO)
  filter(!name_lowercase %in% c('pará', 'côte-d\'ivoire'))

# okay, now do a loose fuzzy match between gapminder names and berkeley names and choose the best reuslts for each gapminder file. this strips out whitespace and punctuation first, as they bias the fuzzy matching algorithm
message(run.time(), ' fuzzy joining gapminder and berkeley country names')
gapdata_names = data_frame(
  name = unique(gapdata$name),
  name_nopunc = str_to_lower(str_replace_all(name, ' ', '')))
name_matches =
  data_frame(
    name_lowercase = unique(berk_files$name_lowercase),
    name_lowercase_nopunc = str_replace_all(name_lowercase, '-', ''))

name_matches %<>%
  stringdist_inner_join(gapdata_names, by = c(name_lowercase_nopunc = 'name_nopunc'),
    max_dist = 5, distance_col = 'match_dist') %>%
  group_by(name) %>%
  top_n(-1, wt = match_dist) %>%
  ungroup() %>%
  filter(match_dist <= 1) %>%
  select(name, name_lowercase, match_dist)

# now bolt the matches onto the berkeley list and the gapminder data
berk_files %<>% inner_join(name_matches, by = 'name_lowercase')
gapdata %<>% inner_join(name_matches, by = 'name')

# TODO - got about 160 countries between all datasets at this point
# might need to fiddle with the strings to get the edge cases...

# download berkeley files, tag each one with the country and bind them together
temp =
  lapply(
    berk_files$name_lowercase, function(x)
    {
      if (!file.exists(paste0('data/', x, '-TAVG-Trend.txt')))
      {
        message(run.time(), ' downloading berkeley temperature data for ', x)
        download.file(paste0(berk_url, x, '-TAVG-Trend.txt'),
          destfile = paste0('data/', x, '-TAVG-Trend.txt'))
      } else
      {
        message(run.time(), ' found berkeley temperature data for ', x)
      }
      read_table2(
        paste0('data/', x, '-TAVG-Trend.txt'),
        comment = '%', skip = 1, col_types = 'ii--dd------',
        col_names = FALSE) %>%
        mutate(name_lowercase = x)
    }) %>%
  bind_rows %>%
  rename(year = X1, month = X2, temp = X5, temp_unc = X6) %>%
  filter(year >= year_start & year <= year_end & month == 6) %>%
  select(-month) %>%
  mutate(
    temp_min = temp - temp_unc,
    temp_max = temp + temp_unc) %>%
  inner_join(name_matches, by = 'name_lowercase')

# finally, join the datasets together (and order them by devrank for each
# year for the plot)
message(run.time(), ' joining berkeley and gapminder data')
all_data =
  inner_join(gapdata, temp,
    by = c('name', 'name_lowercase', 'year', 'match_dist'))
  # arrange(year, annual_devrank)
write_csv(all_data, 'data/gapminder-berkeley-tidy.csv')

message(run.time(), ' building steam train plot')

bubble_data = all_data %>%
  select(co2, pop_poorer_fraction, pop_fraction, year, emission_id) %>%
  rename(emission_year = year)
  # mutate(age = 0)

# bubble_list = list(bubble_data, bubble_data, bubble_data, bubble_data,
#   bubble_data, bubble_data, bubble_data, bubble_data, bubble_data, bubble_data)
# for (i in 1:length(bubble_list))
# {
#   bubble_list[[i]]$age = i - 1
#   bubble_list[[i]]$emission_year = bubble_list[[i]]$emission_year + i - 1
# }
# b
# bubble_list %<>% bind_rows
# bubble_list = split(bubble_list, bubble_list$emission_year)

tw = tween_appear(bubble_data, time = 'emission_year')

bubble_plot = ggplot(tw) +
  geom_point(
    aes(
      x = pop_poorer_fraction + pop_fraction / 2,
      y = .age,
      size = co2,
      frame = .frame))
animation::ani.options(interval = 1/10)
gganimate(bubble_plot, '~/Desktop/steamtrain-out/bubble.mp4',
  ani.width = 800, ani.height = 600)
# tw = tween_states(bubble_list, tweenlength = 1, statelength = 0.25,
#   ease = 'linear', nframes = (year_end - year_start) * 5)

# changing the order of the bars each frame doesn't look like it's going
# to happen easily. instead, i might calculate the 'cumulative population'
# and use this to position each bar manually.
# actually, maybe i'll forget using ggplotly or even gganimate and just
# manually create the frames

# okay, new approach using tweenr: break all_data up into a list of data frames,
# then manually convert country to an ordered factor for each year list element.
# then gganimate...? maybe?

# data_by_year = list(
#   all_data %<>% mutate(age = 0),
#   all_data %<>% mutate(age = 10, year = year + 10))

# data_by_year %<>% bind_rows

# emission bubbles plot
# emission_tweens = tween_states(data_by_year, tweenlength = 1,
#   statelength = 0.25, ease = 'linear', nframes = (year_end - year_start) * 5)

# emission_plot = ggplot(emission_tweens) +
#   geom_point(aes(x = pop_poorer_fraction + (pop_fraction / 2), y = ))
