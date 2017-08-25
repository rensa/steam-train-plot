# build fancy steam train plot from downloaded gapminder and berkeley earth data
# james goldie ('rensa'), august 2017

library(RCurl)
library(rvest)
library(tidyverse)
library(magrittr)
library(stringr)
library(fuzzyjoin)
library(gganimate)
library(tweenr)
filter = dplyr::filter # this is going to kill me one day
source('util.r')

# constants
on_url = 'https://raw.githubusercontent.com/open-numbers/'
berk_url = 'http://berkeleyearth.lbl.gov/auto/Regional/TAVG/Text/'
year_start = 1900
year_end = 2012
frames_per_year = 30
plot_font_1 = 'Helvetica Neue Light'
plot_font_2 = 'Helvetica Neue'

# create data directory if it's missing
if(!dir.exists('data'))
{
  dir.create('data')
}

# download gapminder files if they're missing
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

# load and tidy gapminder country code maps
message(run.time(), ' loading and tidying any missing gapminder data')
geo_gap =
  read_csv('data/ddf--entities--geo--country.csv') %>%
  select(country, name)
geo_co2 =
  read_csv('data/ddf--entities--country.csv')

# load and tidy gapminder data sets
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

# finally, join the datasets together
message(run.time(), ' joining berkeley and gapminder data')
all_data =
  inner_join(gapdata, temp,
    by = c('name', 'name_lowercase', 'year', 'match_dist'))
write_csv(all_data, 'data/gapminder-berkeley-tidy.csv')

message(run.time(), ' trimming excess data for bubble plot')
bubble_data = all_data %>%
  select(co2, pop_poorer_fraction, pop_fraction, year, emission_id) %>%
  mutate(emission_year = year - year_start)
bar_data = all_data %<>%
  select(name, temp, pop_poorer_fraction, pop_fraction, year) %>%
  mutate(
    emission_year = year - year_start,
    ease = 'exponential-in-out')

message(run.time(), ' interpolating emissions and temp data for animation')
bubble_tw = tween_appear(bubble_data, time = 'emission_year',
  timerange = c(year_start, year_end),
  nframes = frames_per_year * (year_end - year_start + 5))
bar_tw = tween_elements(bar_data, time = 'emission_year',
  group = 'name', ease = 'ease',
  nframes = frames_per_year * (year_end - year_start + 5))

message(run.time(), ' building emissions plot')
stplot = ggplot() +
  # temperature columns
  geom_col(data = bar_tw,
    aes(
      x = pop_poorer_fraction + pop_fraction / 2,
      y = temp,
      # fill = temp,
      width = pop_fraction,
      frame = .frame),
    position = 'identity', fill = '#ffdf00') +
  # annual emission bubbles
  geom_jitter(data = bubble_tw,
    aes(
      x = pop_poorer_fraction + pop_fraction / 2,
      y = 1.75 * atan(2 * .age) + 0.3 * sin(2 * .age),
      size = co2,
      frame = .frame),
    alpha = 0.1, width = 0, height = 0.1, colour = '#333333') +
  annotate('text', x = 0.0375, y = 0.125, size = 14, label = 'Poorest',
    family = plot_font_1) +
  annotate('text', x = 0.945, y = 0.125, size = 14, label = 'Wealthiest',
    family = plot_font_1) +
  scale_x_continuous(labels = scales::percent,
    name = 'Percentile of GDP per capita (2010 $US)',
      breaks = seq(0, 1, 0.25), limits = c(0, 1), expand = c(0, 0.02)) +
  scale_y_continuous(breaks = 1:3, limits = c(0, 3.5),
    name = 'Temperature anomaly (°C)', expand = c(0, 0)) +
  scale_size_area(name = 'Annual CO2 emissions (excluding land use)',
    max_size = 80, guide = FALSE) +
  ggtitle('Historical CO2 emissions, GDP per capita and temperature rise',
    subtitle = paste('Who contributed to the greenhouse effect,',
      'and who suffers for it?')) +
  theme_classic(base_size = 32, base_family = plot_font) +
  theme(
    plot.title = element_text(family = plot_font_2, face = 'bold'),
    plot.margin = margin(rep(20, 4), 'px'),
    axis.ticks.x = element_blank(),
    axis.line.y = element_blank(),
    axis.ticks.y = element_blank())

message(run.time(), ' rendering emissions plot')
animation::ani.options(interval = 0.5 / frames_per_year)
gganimate(stplot, '~/Desktop/steamtrain-out/bubble_gdppc_scaled.mp4',
  ani.width = 1920, ani.height = 1080, title_frame = FALSE)

message(run.time(), ' done!')
