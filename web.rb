#require 'pry-byebug'

# NB : ConceptStatus = "Approved", MappingStatus = "approved" #

###
# Vocabularies
##
MU_KPIS = RDF::Vocabulary.new(MU.to_uri.to_s + "kpis/")
MU_MP = RDF::Vocabulary.new(MU.to_uri.to_s + "mapping-platform/")
DCT = RDF::Vocabulary.new("http://purl.org/dc/terms/")

=begin
      TODO : Create a helper to get all results
      TODO : make sure the parameters are correct
=end

###
# Calls
###

get '/kpis/version' do
  { version: "0.0.2" }.to_json
end

get '/kpis/:id' do
  content_type 'application/vnd.api+json'
  id = params[:id]
  res = fetch_kpi(id)
  {
    data: {
      attributes: res,
      self: id
    }
  }.to_json
end

get '/kpis/:id/run' do
  content_type 'application/vnd.api+json'
  id = params[:id]
  kpi = fetch_kpi(id)

  res = run_kpi(kpi, params)
  if kpi["multiValue"] == "false"
    ret = {
      data:{
        attributes: res,
        links:{self: id}
      }
    }
  else
    l = []
    for index in 0 ... res.size
      l[index] = {
        type: "observation",
        attributes: res[index],
        self: "#{id}/observation/#{index}"
      }
    end
    ret = {
      data:{
        attributes: kpi,
        self: id,
        relationships: {
          observations: {
            data:l
          }
        }
      }
    }
  end
  ret.to_json

end


###
# Helpers
###

helpers do
  def run_kpi(kpi, params)
    newquery = replace_params(kpi["query"], params)
    res = query(newquery)
    puts "Query : "+newquery.to_s
    ret = nil
    if kpi["multiValue"] == "false"
      puts "singleValue"
      ret = first_result res
    else
      puts "multiValue"
      ret = all_results res
    end
    ret
  end

  def replace_params(query, params)
    params.each do | key, value |
      if key.is_a?(String) && value.is_a?(String)
        key = escape_string_parameter(key)
        value = escape_string_parameter(value)
        if key.start_with?("kpi-")
          query = query.gsub("##{key.dup.sub('kpi-', '')}", value)
        end
      end
    end
    query
  end

  def fetch_kpi (id)
    first_result query "SELECT ?label ?multiValue ?query WHERE {
      ?kpi <#{MU_CORE.uuid}> '#{id}';
           <#{MU_KPIS.query}> ?query .

      OPTIONAL {
        ?kpi <#{DCT.title}> ?label .
        ?kpi <#{MU_KPIS.multiValue}> ?multiValue .
      }
    }"
  end

  ###
  # Parses the result of a query to an object
  # the keys of the object are the variable names of the query, the values are the bindings of the
  # query result. The object is the first result of the query.
  # TODO fix comments
  ###
  def first_result (result)
    # TODO extract to template
    object = {}

    first = result.first()
    if not first
      return nil
    end

    first.each_binding do |name, value|
      object[name.to_s] = value.to_s
    end
    object
  end

  def all_results (result)
    list = []

    result.each_solution do |row|
      object={}
      result.variable_names.each do |name|
        object[name.to_s] = row.bindings[name].to_s
      end
      list.push object
    end
    list
  end

  def escape_string_parameter (parameter)
    newparameter = parameter.gsub /["']/, '\"'
    newparameter
  end

end
