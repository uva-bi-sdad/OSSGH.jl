# Structs
"""
    Limits

GitHub API limits.

It includes how many remaining queries are available for the current time period and when it resets.

# Fields
- `limit::UInt16`
- `remaining::UInt16`
- `reset::DateTime`
"""
mutable struct Limits
    limit::UInt16
    remaining::UInt16
    reset::DateTime
end
"""
    GitHubPersonalAccessToken(login::AbstractString,
                              token::AbstractString,
                              )::GitHubPersonalAccessToken

A GitHub Personal Access Token

# Fields

- `login::String`
- `token::String`
- `client::Client`
- `limits::Limits`
"""
struct GitHubPersonalAccessToken
    login::String
    token::String
    client::Client
    limits::NamedTuple{(:core, :search, :graphql),NTuple{3,Limits}}
    function GitHubPersonalAccessToken(login::AbstractString, token::AbstractString)
        client = GraphQLClient(
            GITHUB_GRAPHQL_ENDPOINT,
            auth = "bearer $token",
            headers = Dict("User-Agent" => login),
            )
        # Dummy values
        limit = Limits(0, 0, DateTime(now(utc_tz), UTC))
        limits = (core = limit, search = limit, graphql = limit)
        output = new(login, token, client, limits)
        # Update dummy values for actual ones
        update!(output)
    end
end
summary(io::IO, obj::GitHubPersonalAccessToken) = println(io, "GitHub Personal Access Token")
function show(io::IO, obj::GitHubPersonalAccessToken)
    summary(io, obj)
    println(io, "  login: $(obj.login)")
    println(io, "  core remaining: $(obj.limits.core.remaining)")
    println(io, "  core reset: $(obj.limits.core.reset)")
    println(io, "  graphql remaining: $(obj.limits.graphql.remaining)")
    println(io, "  graphql reset: $(obj.limits.graphql.reset)")
end
function update!(obj::GitHubPersonalAccessToken)
    response = request(
        "GET",
        "$GITHUB_REST_ENDPOINT/rate_limit",
        [
            "Accept" => "application/vnd.github.v3+json",
            "User-Agent" => obj.login,
            "Authorization" => "token $(obj.token)",
        ],
    )
    json = JSON3.read(response.body).resources
    obj.limits.core.remaining = json.core.remaining
    obj.limits.core.reset = DateTime(ZonedDateTime(unix2datetime(json.core.reset), utc_tz), UTC)
    obj.limits.search.remaining = json.search.remaining
    obj.limits.search.reset = DateTime(ZonedDateTime(unix2datetime(json.search.reset), utc_tz), UTC)
    obj.limits.graphql.remaining = json.graphql.remaining
    obj.limits.graphql.reset = DateTime(ZonedDateTime(unix2datetime(json.graphql.reset), utc_tz), UTC)
    obj
end
"""
    graphql(obj::GitHubPersonalAccessToken,
            operationName::AbstractString,
            vars::Dict{String};
            max_retries::Integer = 3)

Return JSON of the GraphQL query.
"""
function graphql(
    # obj::GitHubPersonalAccessToken = PARALLELENABLER.pat,
    query::AbstractString = query,
    operationName::AbstractString = string(match(r"(?<=query )\w+(?=[\(|\{])", query).match);
    vars::Dict{String} = Dict{String,Any}(),
    max_retries::Integer = 3,
    )
    obj = PARALLELENABLER.pat
    # operationName = match(r"(?<=query )\w+", query).match
    update!(obj)
    if iszero(obj.limits.graphql.remaining)
        w = obj.limits.graphql.reset - DateTime(now(utc_tz), UTC)
        sleep(max(w, zero(w)))
        obj.limits.graphql.remaining = obj.limits.graphql.limit
    end
    result = try
        obj.client.Query(query, operationName = operationName, vars = vars)
    catch err
        err
    end
    retries = 0
    # Either it exceeded the rate limit or it timeout (for those we retry threee times)
    isok = isa(result, Result) &&
        result.Info.status == 200 &&
        result.Data ≠ """{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"""
    while !isok && retries < max_retries
        sleep(61)
        result = try
            obj.client.Query(query, operationName = operationName, vars = vars)
        catch err
            err
        end
        isok = isa(result, Result) &&
            result.Info.status == 200 &&
            result.Data ≠ """{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"""
        retries += 1
    end
    # @assert isok (query = query, vars = vars, result = result)
    update!(obj)
    result
end
"""
    setup(dbname::AbstractString = "sdad",
          schema::AbstractString = "gh_2007_\$(Dates.year(floor(now(), Year) - Day(1)))",
          )::Nothing

Sets up your PostgreSQL database for the project.

# Example

```julia-repl
julia> setup()

```
"""
function setup(dbname::AbstractString = "sdad", schema::AbstractString = "gh_2007_$(year(floor(now(utc_tz), Year) - Day(1)))")
    conn = Connection("dbname = $dbname")
    pat = DataFrame(execute(conn, "SELECT login, token FROM $schema.pats ORDER BY login LIMIT 1;"))
    pat = only(GitHubPersonalAccessToken.(pat.login, pat.token))
    GHOSS.PARALLELENABLER.conn = Connection("dbname = $dbname")
    GHOSS.PARALLELENABLER.schema = schema
    GHOSS.PARALLELENABLER.pat = pat
    execute(conn,
            replace(join(["CREATE EXTENSION IF NOT EXISTS btree_gist; CREATE SCHEMA IF NOT EXISTS schema;",
                          String(read(joinpath(@__DIR__, "assets", "sql", "licenses.sql"))),
                          String(read(joinpath(@__DIR__, "assets", "sql", "queries.sql"))),
                          String(read(joinpath(@__DIR__, "assets", "sql", "repos.sql"))),
                          String(read(joinpath(@__DIR__, "assets", "sql", "commits.sql"))),
                         ],
                        ' '),
                    "schema" => schema))
    nothing
end

"""
    setup_parallel(limit::Integer = 0)::Nothing

Setup workers.
"""
function setup_parallel(limit::Integer = 0)
    @unpack conn, schema = PARALLELENABLER
    dbname = match(r"(?<=dbname = ).*(?=\n)", string(PARALLELENABLER.conn)).match
    if limit > 0
        pat = DataFrame(execute(conn, "SELECT login, token FROM $schema.pats ORDER BY login LIMIT $limit;"))
    else
        pat = DataFrame(execute(conn, "SELECT login, token FROM $schema.pats ORDER BY login;"))
    end
    pats = GitHubPersonalAccessToken.(pat.login, pat.token)
    npats = length(pats)
    addprocs(npats, exeflags = `--proj`)
    remotecall_eval(Main, workers(), :(using GHOSS))
    @everywhere workers() dbname = $dbname
    @everywhere workers() GHOSS.PARALLELENABLER.conn = Connection("dbname = $dbname")
    @everywhere workers() GHOSS.PARALLELENABLER.schema = $schema
    GHOSS.READY.x = Vector{Future}(undef, npats)
    for proc ∈ workers()
        GHOSS.READY.x[proc - 1] = GHOSS.@spawnat proc nothing
        pat = pats[proc - 1]
        expr = :(GHOSS.PARALLELENABLER.pat = $pat)
        remotecall_eval(Main, proc, expr)
    end
end
