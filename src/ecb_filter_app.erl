%%%-------------------------------------------------------------------
%%% @doc European Central Bank daily exchange rates agent.
%%%
%%% Fetches the ECB euro reference rates XML feed (updated daily,
%%% ~30 currencies) and returns embryos for each rate or a filtered
%%% subset when a specific currency is requested.
%%%
%%% No API key required.
%%%
%%% Deduplication by URL is handled upstream by the Emquest pipeline.
%%%
%%% === Capability cascade ===
%%%
%%%   base_capabilities/0 extends em_filter:base_capabilities().
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(ecb_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(RATES_URL,
    "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml").

%%====================================================================
%% Capability cascade
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"ecb">>, <<"exchange_rates">>,
                                      <<"currency">>, <<"finance">>,
                                      <<"euro">>].

%%====================================================================
%% Application lifecycle
%%====================================================================

start(_Type, _Args) ->
    case ecb_filter_sup:start_link() of
        {ok, Pid} ->
            ok = start_pop_and_http(),
            {ok, Pid};
        Error ->
            Error
    end.

stop(_State) ->
    catch cowboy:stop_listener(ecb_filter_query_listener),
    catch em_pop_sup:stop_node(ecb_filter),
    ok.

%%====================================================================
%% Internal
%%====================================================================

start_pop_and_http() ->
    PopPort   = application:get_env(ecb_filter, pop_port,   9426),
    QueryPort = application:get_env(ecb_filter, query_port, 9427),
    Seeds     = application:get_env(ecb_filter, pop_seeds,  []),
    Vec = em_filter_vec:from_capabilities(base_capabilities()),
    catch em_pop_sup:stop_node(ecb_filter),
    catch cowboy:stop_listener(ecb_filter_query_listener),
    {ok, PopPid} = em_pop_sup:start_node(ecb_filter, #{
        port            => PopPort,
        query_port      => QueryPort,
        vector          => Vec,
        max_peers       => 100,
        gossip_interval => 5_000
    }),
    lists:foreach(
        fun({H, P}) -> catch em_pop_node:add_peer(PopPid, H, P) end,
        Seeds),
    Dispatch = cowboy_router:compile([
        {'_', [{"/agent/query", em_filter_http,
                #{server => ecb_filter_server}}]}
    ]),
    {ok, _} = cowboy:start_clear(ecb_filter_query_listener,
                                  [{port, QueryPort}],
                                  #{env => #{dispatch => Dispatch}}),
    logger:notice("[ecb_filter] gossip port ~w  query port ~w",
                  [PopPort, QueryPort]),
    ok.

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Rate fetching and XML parsing
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Currency, Timeout} = extract_params(JsonBinary),
    fetch_rates(Currency, Timeout).

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Currency = case maps:get(<<"currency">>, Map,
                                     maps:get(<<"value">>, Map,
                                     maps:get(<<"query">>, Map, <<"">>))) of
                <<"">> -> undefined;
                C      -> string:uppercase(binary_to_list(C))
            end,
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 10;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            {Currency, Timeout};
        _ ->
            {undefined, 10}
    catch
        _:_ -> {undefined, 10}
    end.

fetch_rates(Currency, Timeout) ->
    case httpc:request(get, {?RATES_URL, []},
                       [{timeout, Timeout * 1000},
                        {ssl, [{verify, verify_none}]}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            parse_xml(binary_to_list(Body), Currency);
        _ ->
            []
    end.

%% Parse <Cube currency='USD' rate='1.0823'/> entries
parse_xml(Xml, Filter) ->
    case re:run(Xml, "time='([^']+)'", [{capture, all_but_first, list}]) of
        {match, [Date | _]} -> ok;
        _                   -> Date = ""
    end,
    Pairs = re:split(Xml, "<Cube currency='", [{return, list}]),
    Entries = tl(Pairs),   %% drop preamble
    lists:filtermap(fun(E) -> parse_entry(E, Date, Filter) end, Entries).

parse_entry(Entry, Date, Filter) ->
    case re:run(Entry, "^([A-Z]+)'\\s+rate='([^']+)'", [{capture, all_but_first, list}]) of
        {match, [Ccy, Rate]} ->
            case Filter of
                undefined -> build_embryo(Ccy, Rate, Date);
                Ccy       -> build_embryo(Ccy, Rate, Date);
                _         -> false
            end;
        _ ->
            false
    end.

build_embryo(Currency, Rate, Date) ->
    Url    = "https://www.ecb.europa.eu/stats/policy_and_exchange_rates/euro_reference_exchange_rates/",
    Resume = lists:flatten(io_lib:format("1 EUR = ~s ~s (~s)", [Rate, Currency, Date])),
    {true, #{
        <<"properties">> => #{
            <<"url">>      => list_to_binary(Url),
            <<"resume">>   => list_to_binary(Resume),
            <<"currency">> => list_to_binary(Currency),
            <<"rate">>     => list_to_binary(Rate),
            <<"date">>     => list_to_binary(Date),
            <<"base">>     => <<"EUR">>,
            <<"source">>   => <<"ecb.europa.eu">>
        }
    }}.
