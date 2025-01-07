import excel "/Users/edwardchen/Desktop/6104/ECON6104_Dataset_for_Assignments.xlsx", firstrow clear
*** DATA CLEANING
** 1
* Parse the transaction date
gen IDATE_date = date(IDATE, "DMY")
format IDATE_date %td

* Extract year and month from the transaction date
gen year = year(IDATE_date)
gen month = month(IDATE_date)
gen time_id = ym(year, month)
format time_id %tm

* Extract the single floor number
gen floor_num = .
replace floor_num = real(substr(floor, 1, strpos(floor, "/F") - 1)) if strpos(floor, "/F") > 0

* Create a unique property ID
gen property_id = ename + "_" + phase + "_" + bname + "_" + room + "_" + string(floor_num)

* Add a transaction ID
gen transaction_id = property_id + "_" + string(IDATE_date)

* Save the cleaned transaction data
gen merge_id = 1
save "transaction_data_cleaned.dta", replace

** 2
import delimited "/Users/edwardchen/Desktop/6104/individual assignment/mtr_station_data.csv", clear

* Rename columns for clarity
rename name station_name
rename district station_district
rename opened station_opened
rename code station_code
rename latitude station_lat
rename longitude station_lng


* Parse the station opening date
gen station_opened_date = date(station_opened, "DMY", 2025)
format station_opened_date %td

* Add merge_id to facilitate cross join
gen merge_id = 1

* Save the cleaned MTR station data
save "mtr_station_data_clean.dta", replace


** 3
use "transaction_data_cleaned.dta", clear

* Create a grouping variable for splitting the dataset
gen chunk_id = ceil(_n / 1000)  // Adjust "1000" based on memory capacity


* Save each chunk
levelsof chunk_id, local(chunks)
foreach c of local chunks {
    preserve
    keep if chunk_id == `c'
    save "transaction_chunk_`c'.dta", replace
    restore
}

** 3.1merge
local num_chunks = 166
forval i = 1/`num_chunks' {
    display "Processing data for chunk `i'..."

    * Load the current chunk
    use "transaction_chunk_`i'.dta", clear

    * Join with MTR station data
    joinby merge_id using "mtr_station_data_clean.dta"

    * Filter for eligible stations
    gen station_eligible = IDATE_date >= station_opened_date
    keep if station_eligible

    * Save the processed chunk
    save "processed_chunk_`i'.dta", replace
}

** 3.2 Calculte distance to all mtr station
local num_chunks = 166
forval i = 1/`num_chunks' {
    display "Processing geospatial data for chunk `i'..."

    * Load the current chunk
    use "processed_chunk_`i'.dta", clear
	
	* Calculate Haversine distance
    gen delta_lat = (lat - station_lat) * _pi / 180
    gen delta_lng = (lng - station_lng) * _pi / 180
    gen a = sin(delta_lat / 2)^2 + cos(lat * _pi / 180) * cos(station_lat * _pi / 180) * sin(delta_lng / 2)^2
    gen dis_to_mtr = 2 * 6371 * atan2(sqrt(a), sqrt(1-a))

    * Save the processed chunk
    save "geo_processed_chunk_`i'.dta", replace

    
}
** 3.3 Calculte min_distance to mtr station
local num_chunks = 166
forval i = 1/`num_chunks' {
    display "Processing nearest MTR station for chunk `i'..."

    * Load the current chunk
    use "geo_processed_chunk_`i'.dta", clear

    * Find the minimum distance for each property
    egen min_distance = min(dis_to_mtr), by(property_id)

    * Keep only the rows with the nearest MTR station
    keep if dis_to_mtr == min_distance

    * Save the filtered chunk
    save "geo_processed_chunk_`i'.dta", replace

    display "Chunk `i' processed and saved."
}

** 3.4 Append all the processed chunk into a combined dataset
local num_chunks = 166

* Load the first chunk
use "geo_processed_chunk_1.dta", clear

* Append the remaining chunks
forval i = 2/`num_chunks' {
    display "Appending chunk `i'..."

    * Append the next chunk
    append using "geo_processed_chunk_`i'.dta"
}

* Save the combined dataset
save "transaction_data_with_mtr_info.dta", replace




*** Step 3: Clean and transform variables
* Log transaction price, set negative or zero values to missing
gen ln_CONSIDER = .
replace ln_CONSIDER = ln(CONSIDER) if CONSIDER > 0

* Clean usable and gross floor areas (ufa, gfa)
replace ufa = . if ufa <= 0 | gfa <= ufa
replace gfa = . if ufa <= 0 | gfa <= ufa
* Extract and clean floor number
replace floor_num = real(substr(floor, 1, strpos(floor, "/F") - 1)) if strpos(floor, "/F") > 0
gen start_floor = real(substr(floor, 1, strpos(floor, "-") - 1)) if strpos(floor, "-") > 0 & strpos(floor, "/F") > 0
gen end_floor = real(substr(floor, strpos(floor, "-") + 1, strpos(floor, "/F") - strpos(floor, "-") - 1)) if strpos(floor, "-") > 0 & strpos(floor, "/F") > 0
replace floor_num = (start_floor + end_floor) / 2 if !missing(start_floor) & !missing(end_floor)
replace floor_num = 0 if strpos(floor, "G/F")
replace floor_num = real(substr(floor, 1, strpos(floor, "A/F") - 1)) + 1 if strpos(floor, "A/F") > 0
drop start_floor end_floor

** Calculate distance to the city center (city center coordinate: HongKong Exchange Square coordinate)
gen lat_center = 22.1702
gen lng_center = 114.0930
gen delta_lat_center = (lat - lat_center) * _pi / 180
gen delta_lng_center = (lng - lng_center) * _pi / 180
gen b = sin(delta_lat / 2)^2 + cos(lat * _pi / 180) * cos(lat_center * _pi / 180) * sin(delta_lng_center / 2)^2
gen distance_to_center = 2 * 6371 * atan2(sqrt(b), sqrt(1-b))
drop delta_lat delta_lng b  // Drop intermediate variables
* Step 5: Calculate building age
gen occupation_date = date(occupation, "MY")
format occupation_date %td
gen years_since_occupation = (IDATE_date - occupation_date) / 365.25
gen rounded_years_since_occupation = floor(years_since_occupation)
* Step 6: Create district dummies
tabulate district, generate(district_dummy)
drop if year == 1990

save "transaction_data_with_mtr_info_clean.dta", replace

** Define Poor, Middle, Rich class
gen price_per_sqft = (CONSIDER * 1000000) / ufa  // Calculate price per square foot

bysort year (price_per_sqft): egen p20 = pctile(price_per_sqft), p(20)
bysort year (price_per_sqft): egen p80 = pctile(price_per_sqft), p(80)

gen group = .
replace group = 1 if price_per_sqft <= p20    // Poor group
replace group = 2 if price_per_sqft > p20 & price_per_sqft < p80  // Middle group
replace group = 3 if price_per_sqft >= p80   // Rich group

label define group_label 1 "Poor" 2 "Middle" 3 "Rich"
label values group group_label

** Define near MTR station
* Generate the dummy variable for proximity to MTR station
gen near_mtr = dis_to_mtr <= 0.5

* Label the dummy variable for clarity
label define near_mtr_label 0 "Not Near" 1 "Near"
label values near_mtr near_mtr_label
* Check the summary of the new variable
tabulate near_mtr

** Define time periods based on the year variable
gen period_1990_1995 = (year >= 1990 & year <= 1995)
gen period_1996_2000 = (year >= 1996 & year <= 2000)
gen period_2001_2010 = (year >= 2001 & year <= 2010)
gen period_2011_2015 = (year >= 2011 & year <= 2015)
gen period_2016_2020 = (year >= 2016 & year <= 2020)
gen period_2021_2024 = (year >= 2021 & year <= 2024)
* Verify dummy variables
tabulate period_1990_1995
tabulate period_1996_2000
tabulate period_2001_2010
tabulate period_2011_2015
tabulate period_2016_2020
tabulate period_2021_2024

save "transaction_data_with_mtr_info_before_regression.dta", replace
use "transaction_data_with_mtr_info_before_regression.dta", clear


*** REGRESSION
** Basic Regression
reg ln_CONSIDER near_mtr ufa floor_num distance_to_center swimmingpool clubhouse eunits ebuildings bfloors funits school rounded_years_since_occupation period_1996_2000 period_2001_2010 period_2011_2015 period_2016_2020 period_2021_2024

reg ln_CONSIDER near_mtr ufa floor_num distance_to_center swimmingpool clubhouse eunits ebuildings bfloors funits school rounded_years_since_occupation period_1996_2000 period_2001_2010 period_2011_2015 period_2016_2020 period_2021_2024


** Group-Specific Regressions
* For rich group
reg ln_CONSIDER near_mtr ufa floor_num distance_to_center swimmingpool clubhouse eunits ebuildings bfloors funits school rounded_years_since_occupation period_1996_2000 period_2001_2010 period_2011_2015 period_2016_2020 period_2021_2024 if group == 3

* For middle class group
reg ln_CONSIDER near_mtr ufa floor_num distance_to_center swimmingpool clubhouse eunits ebuildings bfloors funits school rounded_years_since_occupation period_1996_2000 period_2001_2010 period_2011_2015 period_2016_2020 period_2021_2024 if group == 2

* For poor group
reg ln_CONSIDER near_mtr ufa floor_num distance_to_center swimmingpool clubhouse eunits ebuildings bfloors funits school rounded_years_since_occupation period_1996_2000 period_2001_2010 period_2011_2015 period_2016_2020 period_2021_2024 if group == 1

* Interaction Terms
gen new_group = .
replace new_group = 1 if group == 2  // Middle becomes 1
replace new_group = 2 if group == 1  // Poor becomes 2
replace new_group = 3 if group == 3  // Rich stays 3

label define new_group_label 1 "Middle" 2 "Poor" 3 "Rich"
label values new_group new_group_label

reg ln_CONSIDER near_mtr##i.new_group ufa floor_num distance_to_center swimmingpool clubhouse eunits ebuildings bfloors funits school rounded_years_since_occupation period_1996_2000 period_2001_2010 period_2011_2015 period_2016_2020 period_2021_2024


** Discuss Time-Period
reg ln_CONSIDER near_mtr##i.new_group##i.period_* ufa floor_num distance_to_center swimmingpool clubhouse eunits ebuildings bfloors funits school rounded_years_since_occupation
