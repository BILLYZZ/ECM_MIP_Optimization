# Main file for ECM optimization with Ruby
# Author: Bill Zhai, Jan 8, 2020

#process parameter files 
require 'json'
require 'Matrix'
require 'rglpk'

# Number of each types:
num_ecm = 82; #number of ecm packages
num_bldgType = 13;
num_vintage = 5;
num_climateZone = 9;
b = [];
f = [];
# Read file and populate B and F matrices
file = File.read('./Measures.json')
data = JSON.parse(file)
for e in data
	ecm = e[-1]
	# First prepare the B matrix
	bldgTypeAllowed = Array.new(num_bldgType, 0)
	if ecm.has_key?('Bldg_type')
		bldgTypeList = ecm['Bldg_type'].split(';')
		for i in bldgTypeList
			i = i.to_i # String to integer
			if i.instance_of?(Integer)
				bldgTypeAllowed[i-1] = 1 # Use 0 indexing
			end
		end
	else # If 'Bldg_type' field is missing, assume that this ecm can be used for all types
		bldgTypeAllowed = Array.new(num_bldgType, 1)
	end
	# Append bldgTypeAllowed to the end of B matrix
	b << bldgTypeAllowed
	
	# Then prepare the F matrix
	conflict = Array.new(num_ecm, 2) # '2' means there is no conflict 
	if ecm.has_key?('conflict_measure_ids') # If the field doesn't exist, there are no conflicts
		conflictECMs = ecm['conflict_measure_ids'].split(',')
		for i in conflictECMs
			i = i.to_i # String to integer
			# For non-diagonal entries, '1' means there is a conflict. Per 'Measures.json,'
			# an ECM is 'in conflict' with itself, so the diagonal entries are all 1's
			if i.instance_of?(Integer)
				conflict[i - 1] = 1
			end
		end
	end
	# Append 'conflict' array to the end of F matrix
	f << conflict
end

# Energy savings, CO2 reductions, financial costs:
# Each of these is a 4-d matrix
# Energy saving percentage
s = Array.new(num_bldgType) { Array.new(num_vintage) {Array.new(num_climateZone) {Array.new(num_ecm,0)} } }
# CO2 reduction
cr = Array.new(num_bldgType) { Array.new(num_vintage) {Array.new(num_climateZone) {Array.new(num_ecm,0)} } }
# Financial cost
c = Array.new(num_bldgType) { Array.new(num_vintage) {Array.new(num_climateZone) {Array.new(num_ecm,0)} } }
file = File.read('./measure_savings.json')
data = JSON.parse(file)

for e in data
	saving = e[-1] # The actual saving measure instance json object 
	ecmID = saving['measure_id'].to_i #the corresponding ecm id
	bldgType = saving['building_type_id'].to_i
	vintageID = saving['vintage_id'].to_i
	climateZone = saving['climate_zone'].to_i	
	# Populate S, CR, and C matrices with 0 indexing
	s[bldgType-1][vintageID-1][climateZone-1][ecmID-1] = saving['saving_pct'].to_f
	cr[bldgType-1][vintageID-1][climateZone-1][ecmID-1] = saving['co2_reduction_klbs'].to_f
	c[bldgType-1][vintageID-1][climateZone-1][ecmID-1] = saving['cost'].to_f
end

# Baseline energy lookup matrix:
baseline = Array.new(num_bldgType) { Array.new(num_vintage) {Array.new(num_climateZone, 0) }}
file = File.read('./baseline.json')
data = JSON.parse(file)
for e in data
	bl = e[-1]
	bldgType = bl['building_type_id'].to_i
	vintageID = bl['vintage_id'].to_i
	climateZone = bl['climate_zone'].to_i
	energy = bl['energy'].to_f
	baseline[bldgType-1][vintageID-1][climateZone-1] = energy
end

# Run the optimization
# Obj: max energy saving or CO2 reduction 
# Constraints:
# 1. Optional: total cost less or equal to budget 
# 2. Optional: payback year less or equal to given
# 3. Building compatibility 
# 4. Conflict ecm’s

# 5. Binary decision variables
# 6. Possible: dynamic constraint generation to output the top N solutions
B = b
F = f
C = c
CR = cr
S = s
Baseline = baseline
#print('S')
#print(S)
def optimize(bldgType, vintageID, climateZone, objective, budget, paybackYears)
	puts('Start Optimization...')
	# Convert from 1-indexing to 0-indexing
	bldgType = bldgType - 1
	vintageID = vintageID - 1
	climateZone = climateZone - 1
	# Number of each types:
	num_ecm = 82; #number of ecm packages
	num_bldgType = 13;
	num_vintage = 5;
	num_climateZone = 9;
	p = Rglpk::Problem.new
	p.name = "ECM_optimization_obj_max_energy_saving"
	p.obj.dir = Rglpk::GLP_MAX
	rows = p.add_rows(2+num_ecm+num_ecm*num_ecm-num_ecm)
	rows[0].name = 'budget'
	rows[0].set_bounds(Rglpk::GLP_UP, nil, budget)
	rows[1].name = 'payback_year'
	rows[1].set_bounds(Rglpk::GLP_UP, nil, paybackYears)
	# Building type compatibility constraints
	range = 2..(2+num_ecm-1)
	range.each do |i|
		rows[i].name = 'building_type_compatibility_'+(i-2).to_s
		rows[i].set_bounds(Rglpk::GLP_UP, nil, B[i-2][bldgType])
	end
	# ECM conflict constraints
	n = 2+num_ecm
	(0..num_ecm-1).each do |i|
		(0..num_ecm-1).each do |j|
			if i != j
				rows[n].name = 'ecm_conflict_'+(n-num_ecm-2).to_s
				rows[n].set_bounds(Rglpk::GLP_UP, nil, F[i][j])
				n = n + 1
			end
		end
	end
	puts('NUMBER ROWS:')
	puts(p.rows.size())
	# Columns, aka variables:
	cols = p.add_cols(num_ecm)
	(0..num_ecm-1).each do |i|
		cols[i].kind = Rglpk::GLP_BV
		cols[i].name = 'x_'+i.to_s
	end
	
	if objective == 'energy_saving'
		p.obj.coefs = S[bldgType][vintageID][climateZone]
	end
	
	if objective == 'co2_reduction'
		p.obj.coefs = CR[bldgType][vintageID][climateZone]
	end
	#print('coefs')
	#print(p.obj.coefs)
	# Assemble the 'A' matrix in Ax<=b
	# The so-called 'matrix' here is actually a list (flattened matrix)
	a_matrix_flatten = []
	a_matrix_flatten = a_matrix_flatten + (C[bldgType][vintageID][climateZone]) # budget row
	#print(a_matrix_flatten)
	a_matrix_flatten = a_matrix_flatten + (Array.new(num_ecm, 0)) # payback_year ACTUAL VALUES TO BE IMPLEMENTED
	#print(print(a_matrix_flatten))
	
	# ECM building type compatibility constraints
	(0..num_ecm-1).each do |i|
		row = Array.new(num_ecm, 0)
		row[i] = 1
		a_matrix_flatten = a_matrix_flatten + row
	end
	
	# ECM conflict constraints
	(0..num_ecm-1).each do |i|
		(0..num_ecm-1).each do|j|
			if i != j
				row = Array.new(num_ecm, 0)
				row[i] = 1
				row[j] = 1
				a_matrix_flatten = a_matrix_flatten + row
			end
		end
	end
	
	puts('A matrix size')
	puts(a_matrix_flatten.size)
	
	p.set_matrix(a_matrix_flatten)
	p.mip(presolve: Rglpk::GLP_ON)
	z = p.obj.mip
	results = []
	chosen = []
	totalCost = 0
	totalCO2Red = 0
	totalEnergySavingPct = 0
	if objective == 'energy_saving'
		totalEnergySavingPct = z
		(0..num_ecm-1).each do |i|
			totalCost = totalCost + cols[i].mip_val*C[bldgType][vintageID][climateZone][i]
			totalCO2Red = totalCO2Red + cols[i].mip_val*CR[bldgType][vintageID][climateZone][i]
			results << cols[i].mip_val
			if cols[i].mip_val == 1
				chosen << i+1 # Human readable ecm id is one-indexing
			end
		end	
	end
	if objective == 'co2_reduction'
		totalCO2Red = z
		(0..num_ecm-1).each do |i|
			totalCost = totalCost + cols[i].mip_val*C[bldgType][vintageID][climateZone][i]
			totalEnergySavingPct = totalEnergySavingPct + cols[i].mip_val*S[bldgType][vintageID][climateZone][i]
			results << cols[i].mip_val
			if cols[i].mip_val == 1
				chosen << i+1 # Human readable ecm id is one-indexing
			end
		end	
	end
	
	puts('=================ECM Optimization Result=================')
	puts('Input bldgType:')
	puts(bldgType+1)
	puts('Input vintageID:')
	puts(vintageID+1)
	puts('Input climateZone:')
	puts(climateZone+1)
	puts('Input budget:')
	puts(budget)
	puts('Input paybackYear (not yet implemented):')
	puts(paybackYears)
	puts('Optimal ECMs to be chosen:')
	puts(chosen)
	puts('Baseline energy:')
	puts(Baseline[bldgType][vintageID][climateZone])
	puts('Total financial cost:')
	puts(totalCost)
	puts('Total energy saving pct')
	puts(totalEnergySavingPct)
	puts('Total energy saving val')
	puts(totalEnergySavingPct/100*Baseline[bldgType][vintageID][climateZone])
	puts('Total CO2 Reduction (klbs):')
	puts(totalCO2Red)
end

# Get user inputs:
puts('Enter building type:')
bldgType = gets.chomp.to_i
puts('Enter vintage id:')
vintageID = gets.chomp.to_i
puts('Enter climate zone id:')
climateZone = gets.chomp.to_i
puts('Enter objective: ("1" for energy savings, "2" for co2 reduction)')
objective = 'energy_saving'
if gets.chomp.to_i == 2
	objective = 'co2_reduction'
end
puts('Optional: Enter budget:')
budget = gets.chomp.to_f
puts('Optional: Enter pay-back years:')
paybackYears = gets.chomp.to_f

# Run optimization:
optimize(bldgType, vintageID, climateZone, objective, budget, paybackYears)

