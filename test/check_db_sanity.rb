#!/usr/bin/env ruby

# Copyright 2011 Juha-Jarmo Heinonen <o@sorsacode.com>

require 'rubygems'
require 'yaml'

base_path = File.split( File.split( File.expand_path( __FILE__ ) ).first ).first
$LOAD_PATH << File.join( base_path, 'lib' )

require 'freebombs/logger'
require 'freebombs/db_handler'

class CheckDBSanity < FreeBOMBS::DBHandler

  def log( message )
    puts message if $verbose
  end

  def error( message )
    puts
    puts "Error: "+message
    puts
    exit
  end

  def info( message )
    puts message if $verbose
  end

  def warn( message )
    puts "Warning: "+message
  end

  def valid_url?( url )
    ( url.start_with?('http://') or url.start_with?('https://') ) and url.length > 10
  end

  def check_suppliers
    mandatory_keys = [ 'title', 'homepage', 'currency' ]
    suppliers.each_key do |name|
      info "Checking supplier: #{name}"
      supplier = suppliers[name]
      mandatory_keys.each do |key|
        error "Missing #{key} for supplier #{name}" unless supplier.has_key? key
      end
      unless [ 'USD', 'EUR' ].include? supplier['currency']
        error "Invalid currency: #{supplier['currency'].inspect}"
      end
    end
  end

  def validate_supply( supply_spec )
    unless supply_spec['part'].class == String
      error "Invalid part specification: #{supply_spec['part'].inspect}"
    end
    price_num = supply_spec['price']
    unless [ Float, Fixnum ].include? price_num.class
      error "Invalid price: #{price_num.inspect}"
    end
  end

  def check_components
    # the only mandatory key is title, the rest depends on choices:
    # if the component is obsolete:
    #  - it must either have a valid replacement or no replacement at all!
    # otherwise:
    #  - the item must have a valid supplier specification, including part-number and price
    #    - if any supplier is not defined, issue a warning
    #  - the component must have a datasheet or a description field defined
    mandatory_keys = [ 'title' ]
    components.each_key do |mfg_id|
      info "Checking component: #{mfg_id}"
      component = components[mfg_id]
      mandatory_keys.each do |key|
        error "Component #{mfg_id} is missing #{key}" unless component.has_key? key
      end
      if component['obsolete']
        if component.has_key? 'replacement'
          replacement = component['replacement']
          if components.has_key? replacement
            info "..obsolete, replacement: #{replacement}"
            next
          else
            error "Missing replacement for obsolete component id: #{mfg_id}"
          end
        else
          warn "Obsolete component #{mfg_id} has replacement!"
        end
      else
        component_supply = component['suppliers']
        if component_supply.class != Hash
          error "Invalid component supply specification: #{component_supply}"
        end
        suppliers.each_key do |supplier_name|
          if component_supply.has_key? supplier_name
            validate_supply( component_supply[supplier_name] )
          else
            warn "Component #{mfg_id} has no supply information for supplier: #{supplier_name}"
          end
        end
        if component.has_key? 'datasheet'
          datasheet = component['datasheet']
          if not datasheet.class == String
            error "Invalid type of datasheet URL (datasheet): #{datasheet.inspect}"
          elsif not valid_url?( datasheet )
            error "Invalid format of datasheet URL (datasheet): #{datasheet.inspect}"
          end
        elsif not component.has_key? 'description'
          error "Datasheet URL (datasheet) is missing for component: #{mfg_id}"
        end
        if component.has_key? 'replacement'
          replacement = component['replacement']
          unless components.has_key? replacement
            error "Missing replacement component id: #{replacement.inspect}"
          end
        end
      end
    end
  end

  def missing_keys( keys, hash )
    arr = []
    keys.each { |key| arr.push key unless hash.include? key }
    arr
  end

  def extra_keys( keys, hash )
    arr = []
    hash.each_key { |key| arr.push key unless keys.include? key }
    arr
  end

  def check_component_references( component_references, section_name )
    component_references.each do |component_ref|
      unless [ Array, String ].include? component_ref.class
        error "Expected the component as an Array or a String, got #{component.class}"
      end
      if component_ref.class == String
        component_ref = [ 1, component_ref ]
      end
      unless component_ref.length == 2
        error "The component should consist of a [ amount, 'component_id' ] pair, got: #{component.inspect}"
      end
      component_amount = component_ref[0]
      unless component_amount.class == Fixnum
        error "Expected component amount as a Fixnum, got: #{component_amount.class}"
      end
      component_id = component_ref[1]
      unless component_id.class == String
        error "Expected component id as a String, got: #{component_id.class}"
      end
      unless components.has_key? component_id
        error "Undefined component: #{component_id}"
      end
      @components_used.push component_id unless @components_used.include? component_id
      component = components[component_id]
      if component['obsolete']
        if component.has_key? 'replacement'
          warn "Obsolete component #{component_id} used in the configuration section of #{section_name}"
          info "         It might have a replacement: #{component['replacement'].inspect}"
          @components_used.push component['replacement'] unless @components_used.include? component['replacement']
        else
          error "Obsolete component without replacement defined: #{component_id}"
        end
      end
    end
  end

  def check_config_section( section_name, sections )
    info "Checking configurable section #{section_name}"
    section = sections[section_name]
    unless section.class == Hash
      error "The section must be a Hash, got: #{section.class}"
    end
    mandatory_keys = [ 'title', 'description', 'value', 'min', 'max' ]
    mandatory_keys.each do |key|
      unless section.has_key? key
        error "The section #{section_name} is missing #{key}"
      end
    end
    warn_keys = [ 'components' ]
    warn_keys.each do |key|
      unless section.has_key? key
        warn "The section #{section_name} is missing the #{key} definition"
      end
    end
    { 'title' => String,
      'description' => String,
      'value' => Fixnum,
      'min' => Fixnum,
      'max' => Fixnum,
      'presets' => Array,
      'checked' => [TrueClass, FalseClass],
      'excludes' => [Array, String],
      'components' => Array
    }.each do | key, types |
      next unless section.has_key? key
      if types.class != Array
        types = [ types ]
      end
      unless types.include? section[key].class
        error "Invalid type of #{key}; expected #{types.join(' or ')}; got #{section[key].class}!"
      end
    end
    if section['min'] < 0
      error "The minimum value: #{section['min']} is less than 0"
    end
    if section['min'] > section['max']
      error "The minimum: #{section['min']} is greater than the maximum: #{section['max']}"
    end
    if section['value'] > section['max']
      error "The value: #{section['value']} is greater than the maximum allowed: #{section['max']}"
    end
    if section['value'] < section['min']
      error "The value: #{section['value']} is less than the minimum allowed: #{section['min']}"
    end
    if section.has_key? 'excludes'
      excludes = section['excludes']
      excludes = [ excludes ] unless excludes.class == Array
      excludes.each do |excl_section_name|
        if excl_section_name == section_name
          error "Exclusion of self not supported"
        end
        unless sections.has_key? excl_section_name
          error "Exclusion of undefined section: #{excl_section_name}"
        end
      end
    end
    if section.has_key? 'presets'
      section['presets'].each do |preset|
        error "Missing preset title" unless preset.has_key? 'title'
        error "Expected the title as String, got #{preset['title'].class}" unless preset['title'].class == String
        error "Missing preset value" unless preset.has_key? 'value'
        error "Expected the value as Fixnum, got #{preset['value'].class}" unless preset['value'].class == Fixnum
        if preset['value'] > section['max']
          error "Preset value: #{preset['value']} is larger than the maximum allowed: #{section['max']}"
        end
        if preset['value'] < section['min']
          error "Preset value: #{preset['value']} is less than the minimum allowed: #{section['min']}"
        end
      end
    end
    if section.has_key? 'components'
      check_component_references( section['components'], section_name )
    end
  end

  def check_configurations
    mandatory_keys = [ 'title', 'description', 'components', 'sections', 'section_order' ]
    info "Checking configuration validity"
    mandatory_keys.each do |key|
      error "The configuration is missing #{key}" unless configurations.has_key? key
    end
    section_order = configurations['section_order']
    unless section_order.class == Array
      error "The configurations section_order list must be an Array, got: #{section_order.class}"
    end
    sections = configurations['sections']
    unless sections.class == Hash
      error "The configurations section must be a Hash, got: #{sections.class}"
    end
    missing_sections = missing_keys( section_order, sections )
    unless missing_sections.empty?
      error "The section_order list has these undefined sections: #{missing_sections.join(', ')}"
    end
    extra_sections = extra_keys( section_order, sections )
    unless extra_sections.empty?
      error "The sections have these unordered sections: #{extra_sections.join(', ')}"
    end
    @components_used = []
    check_component_references( configurations['components'], 'Default' )
    section_order.each do |section_name|
      check_config_section( section_name, sections )
    end
  end

  def check_unused_components
    unused_puts = false
    components.each_key do |component_id|
      unless @components_used.include? component_id
        unless unused_puts
          puts "Unused components:"
          unused_puts = true
        end
        puts "  - #{component_id.inspect}"
      end
    end
  end

  def test
    check_suppliers
    check_components
    check_configurations
    check_unused_components
    info "Validation complete."
  end

end

def usage
  puts
  puts "FreeBOMBS database validation tool"
  puts
  puts "Usage: #{$0} [-v] [database_name]"
  puts
  puts "The -v flag switches verbose mode on."
  puts "The database_name is optional."
  puts "By default all databases in the dbs directory are validated."
end

def test_db( test_dbs_path, db_name=false )
  if db_name
    test_db_path = File.expand_path( db_name, test_dbs_path )
  else
    test_db_path = test_dbs_path
  end
  if File.exists?( test_db_path ) and File.directory?( test_db_path )
    CheckDBSanity.new( test_db_path )
  else
    puts "Error: Nonexistent or invalid project path: #{test_db_path}"
    exit
  end
end

def test_all_dbs( test_dbs_path )
  Dir.entries( test_dbs_path ).each do |test_db_name|
    next if test_db_name.start_with?( '.' )
    test_db_path = File.expand_path( test_db_name, test_dbs_path )
    next unless File.directory?( test_db_path )
    puts
    puts "Validating project database #{test_db_name}.."
    test_db( test_db_path )
    puts "Validation of #{test_db_name} completed without errors."
    puts
  end
end

$verbose = false
test_dbs_path = File.join( base_path, 'dbs' )
if ARGV.length == 0
  test_all_dbs( test_dbs_path )
elsif ARGV.length == 1
  if ARGV.first == '-v'
    $verbose = true
    test_all_dbs( test_dbs_path )
  elsif ARGV.first.start_with?('-')
    usage
  else
    test_db( test_dbs_path, ARGV.first )
  end
elsif ARGV.length == 2 and ARGV.first == '-v'
  $verbose = true
  test_db( test_dbs_path, ARGV[1] )
else
  usage
end


