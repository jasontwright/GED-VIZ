require 'currency_converter'

class DataValueImporter < Importer

  # The main import files
  INPUT_FILENAMES = [
    'Prognos_out_bilateral_2015-10-28.csv',
    'Prognos_out_trade_bilateral_2015-10-28.csv'
  ]

  attr_reader :country_id_by_iso3,
              :type_id_by_name, :type_key_by_id,
              :unit_id_by_name, :unit_key_by_id, :unit_id_by_key

  def setup
    @country_id_by_iso3 ||= Hash.new do |hash, iso3|
      hash[iso3] = Country.find_by_iso3(iso3).try(:id)
    end

    @type_id_by_name ||= Hash.new do |hash, name|
      type_info = DataTypeImporter::TYPE_NAME_TO_KEY.fetch(name)
      hash[name] = DataType.where(key: type_info[:key]).pluck(:id).first
    end

    @type_key_by_id ||= Hash.new do |hash, id|
      hash[id] = DataType.find(id).key
    end

    @unit_id_by_name ||= Hash.new do |hash, name|
      key = DataTypeImporter::UNIT_NAME_TO_ATTRIBUTES.fetch(name)[:key]
      hash[name] = Unit.where(key: key).pluck(:id).first
    end

    @unit_key_by_id ||= Hash.new do |hash, id|
      hash[id] = Unit.find(id).key
    end

    @unit_id_by_key ||= Hash.new do |hash, key|
      hash[key] = Unit.where(key: key).pluck(:id).first
    end
  end

  def import
    puts 'DataValueImporter#import'

    puts 'DataValue.delete_all'
    DataValue.delete_all

    INPUT_FILENAMES.each do |input_filename|
      puts "process CSV: #{input_filename}"
      file = folder.join(input_filename)
      CSV.foreach(file, headers: true, return_headers: false, col_sep: ';') do |row|
        result = import_row(row)
        puts "skipping #{row}" unless result
      end
    end
  end

  private

  def import_row(row)
    # Land;Partner;Variable;Einheit;Jahr;Wert;
    # ARG;World;Import;Mrd. US-$;2000;25.3;
    return false unless row[0] and row[1]

    to_iso3 = row[0].downcase
    from_iso3 = row[1].downcase
    return false if from_iso3 == '' || to_iso3 == ''

    # Ignore empty sums
    return false if from_iso3 == 'world' || from_iso3 == 'total'

    type_name = row[2]
    unit_name = row[3]

    year = row[4]
    value = row[5].gsub(',', '.').to_f

    country_from_id = country_id_by_iso3[from_iso3]
    country_to_id = country_id_by_iso3[to_iso3]

    # Ignore unknown countries
    return false if country_from_id.nil? || country_to_id.nil?

    record = {
      year:            year,
      data_type_id:    type_id_by_name[type_name],
      unit_id:         unit_id_by_name[unit_name],
      country_from_id: country_from_id,
      country_to_id:   country_to_id,
      value:           value
    }

    begin
      import_value(record)
    rescue => e
      puts "Error importing:\n#{row.inspect}\n#{record.inspect}"
      raise e
    end
    true
  end

  def import_value(record)
    record = convert_value(record)
    DataValue.create!(record)
    convert_currency(record)
  end

  def convert_value(record)
    type_key = type_key_by_id[record[:data_type_id]]

    if type_key == 'claims'
      # Claims
      # Switch sender and receiver
      # ITA;USA;Foreign Claims;Mio. US-$;2010;36074;BIS
      # means USA owes to Italy (Italy lends money to USA)
      record[:country_from_id], record[:country_to_id] =
        record[:country_to_id], record[:country_from_id]

      # Convert from Mio. US-$ to Bln. US-$
      record[:unit_id] = unit_id_by_name['Bln. US-$']
      record[:value] = record[:value] / 1000

    elsif type_key == 'migration'
      # Migration
      # Convert from thousand persons to persons
      record[:unit_id] = unit_id_by_name['Persons']
      record[:value] = record[:value] * 1000
    end

    record
  end

  def convert_currency(record)
    unit_key = unit_key_by_id[record[:unit_id]]
    year = record[:year]
    value = record[:value]

    CurrencyConverter.convert(unit_key, year, value) do |new_value, new_unit_key|
      if new_value
        record[:unit_id] = unit_id_by_key[new_unit_key]
        record[:value] = new_value
        DataValue.create!(record)
      end
    end
  end

end
