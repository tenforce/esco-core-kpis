require "json"
#require "pry"

# NB : ConceptStatus = "Approved", MappingStatus = "approved" #

###
# Vocabularies
##
MU_KPIS = RDF::Vocabulary.new(MU.to_uri.to_s + "kpis/")
MU_MP = RDF::Vocabulary.new(MU.to_uri.to_s + "mapping-platform/")
DCT = RDF::Vocabulary.new("http://purl.org/dc/terms/")
GRAPH= "http://mu.semte.ch/application"

=begin
      TODO : Create a helper to get all results
      TODO : make sure the parameters are correct
=end

###
# Calls
###

get '/kpis/version' do
  { version: "0.0.3" }.to_json
end

get '/kpis/:id' do
  content_type 'application/vnd.api+json'
  id = params[:id]
  res = fetch_kpi(id, GRAPH)
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
  unless id
    error("No ID was provided.")
  end
  kpi = fetch_kpi(id, GRAPH)
  unless kpi
    error("This KPI does not exist.", 404)
  end
  uri = kpi["uri"]
  kpi.delete('uri')

  # Checking if bypass cache parameter is present
  if !params[:bypassCache] || params[:bypassCache] == "false"
    # First check if there is any persisted result for that specific params
    cached = fetch_cached(id, params, GRAPH)
    if cached
      if (Time.now().to_i - cached["lastCalculated"].to_i) > (1000*3600*24) || !cached["results"]
        # recalculate
        recalculate = true
      else
        # cached is a single result, should never be an array
        res = JSON.parse(cached["results"])
        kpi["lastCalculated"] = cached["lastCalculated"].to_i
      end
    else
      recalculate = true
    end
    # Then check if the lastCalculated is not too old
  else
    recalculate = true
  end


  if recalculate
    # Do the query again
    res = run_kpi(kpi, params)
    time = Time.now().to_i
    save_results(id, params, res, time, GRAPH)
    kpi["lastCalculated"] = time
  end

  # res can either be an array of results or a single result
  if res.is_a?(Array)
    array = res
  else
    array = []
    array[0] = res
  end

  l = []
  for index in 0 ... array.size
    l[index] = {
      type: "observation",
      attributes: array[index],
      links:{self: "#{uri}/observation/#{index}"}
    }
  end
  if recalculate
    kpi["isCachedResult"] = false
  else
    kpi["isCachedResult"] = true
  end
  ret = {
    data:{
      attributes: kpi,
      links:{self: uri},
      relationships: {
        observations: {
          data:l
        }
      }
    }
  }
  ret.to_json

end


###
# Helpers
###

helpers do
  def run_kpi(kpi, params)
    newquery = replace_params(kpi["query"], params)
    res = query(newquery)
    all_results res
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

  def fetch_kpi (id, graph)
    first_result query "SELECT ?uri ?label ?query
      FROM <#{graph}>
      WHERE {
      ?uri <#{MU_CORE.uuid}> '#{id}';
           <#{MU_KPIS.query}> ?query .

      OPTIONAL {
        ?uri <#{DCT.title}> ?label .
      }
    }"
  end

  def build_parameters_query (params, varname="cached")
    parameters =""
    params.each do | key, value |
      if key.is_a?(String) && value.is_a?(String)
        key = escape_string_parameter(key)
        value = escape_string_parameter(value)
        if key.start_with?("kpi-")
          parameters += "?#{varname} <#{MU_KPIS.parameter}-#{key}> '#{value}' ."
        end
      end
    end
    parameters
  end

  def save_results (id, params, results, time, graph)
    parameters1 = build_parameters_query(params, "tmpcached")
    parameters2 = build_parameters_query(params, "cached")

    squery =  "WITH <#{graph}>
      DELETE
      {
        ?tmpcached <#{MU_KPIS.lastCalculated}> ?lastCalculated .
        ?tmpcached <#{MU_KPIS.results}> ?results .
      }
      INSERT
      {
        ?cached <#{MU_KPIS.isCacheFor}> ?uri .
        ?cached <#{MU_KPIS.lastCalculated}> #{time} .
        ?cached <#{MU_KPIS.results}> '#{results.to_json}' .
        #{parameters2}
      }
      WHERE
      {
        ?uri <#{MU_CORE.uuid}> '#{id}'.
        OPTIONAL { ?tmpcached <#{MU_KPIS.isCacheFor}> ?uri .
        #{parameters1}
        }
        BIND(IF(BOUND(?tmpcached), ?tmpcached, URI(CONCAT('#{MU_KPIS.cache}-', STRUUID()))) as ?cached)
        OPTIONAL
        {
        ?cached <#{MU_KPIS.lastCalculated}> ?lastCalculated .
        }
        OPTIONAL
        {
        ?cached <#{MU_KPIS.results}> ?results .
        }
      }"
    update squery
  end

  def fetch_cached (id, params, graph)
    parameters = build_parameters_query(params)

    first_result query "SELECT ?lastCalculated ?results
      FROM <#{graph}>
      WHERE
      {
        ?uri <#{MU_CORE.uuid}> '#{id}'.
        ?cached <#{MU_KPIS.isCacheFor}> ?uri .
        #{parameters}
        OPTIONAL
        {
        ?cached <#{MU_KPIS.lastCalculated}> ?lastCalculated .
        }
        OPTIONAL
        {
        ?cached <#{MU_KPIS.results}> ?results .
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
    parameter.gsub /["']/, '\"'
  end

end

