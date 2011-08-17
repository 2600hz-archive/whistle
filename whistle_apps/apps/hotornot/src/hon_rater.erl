%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2011, VoIP, INC
%%% @doc
%%% Given a rating_req, find appropriate rate for the call
%%% @end
%%% Created : 16 Aug 2011 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(hon_rater).

-export([init/0, handle_req/1]).

-include("hotornot.hrl").

init() ->
    case couch_mgr:db_exists(?RATES_DB) of
	true -> ok;
	false -> init_db()
    end.

init_db() ->
    couch_mgr:db_create(?RATES_DB).

handle_req(JObj) ->
    true = hon_api:rating_req_v(JObj),

    ToDID = wh_util:to_e164(wh_json:get_value(<<"To-DID">>, JObj)),
    FromDID = wh_util:to_e164(wh_json:get_value(<<"From-DID">>, JObj)),
    RouteOptions = wh_json:get_value(<<"Options">>, JObj, []),
    Direction = wh_json:get_value(<<"Direction">>, JObj),
    <<"+", Start:1/binary, Rest/binary>> = ToDID,
    End = <<Start/binary, Rest/binary>>,

    ?LOG("searching for rates in the range ~s to ~s", [Start, End]),
    case couch_mgr:get_results(?RATES_DB, <<"rating/lookup">>, [{<<"startkey">>, wh_util:to_integer(Start)}
								,{<<"endkey">>, wh_util:to_integer(End)}]) of
	{ok, []} -> ?LOG("rate lookup had no results"), {error, no_rate_found};
	{error, _E} -> ?LOG("rate lookup error: ~p", [_E]), {error, no_rate_found};
	{ok, Rates} ->
	    Matching = filter_rates(ToDID, Direction, RouteOptions, Rates),
	    case lists:usort(fun sort_rates/2, Matching) of
		[] -> ?LOG("no rates left after filter"), {error, no_rate_found};
		[Rate|_] ->
		    %% wh_timer:tick("post usort data found"),
		    ?LOG("using rate definition ~s", [wh_json:get_value(<<"rate_name">>, Rate)]),

		    BaseCost = wh_util:to_float(wh_json:get_value(<<"rate_cost">>, Rate)) * wh_util:to_integer(wh_json:get_value(<<"rate_minimum">>, Rate))
			+ wh_util:to_float(wh_json:get_value(<<"rate_surcharge">>, Rate)),

		    {ok, [{<<"Rate">>, wh_util:to_binary(wh_json:get_value(<<"rate_cost">>, Rate))}
			  ,{<<"Rate-Increment">>, wh_util:to_binary(wh_json:get_value(<<"rate_increment">>, Rate))}
			  ,{<<"Rate-Minimum">>, wh_util:to_binary(wh_json:get_value(<<"rate_minimum">>, Rate))}
			  ,{<<"Surcharge">>, wh_util:to_binary(wh_json:get_value(<<"rate_surcharge">>, Rate, 0))}
			  ,{<<"Rate-Name">>, wh_util:to_binary(wh_json:get_value(<<"rate_name">>, Rate))}
			  ,{<<"Base-Cost">>, wh_util:to_binary(BaseCost)}
			 ]}
	    end
    end.


filter_rates(To, Direction, RouteOptions, Rates) ->
    [ begin
	  Rate = wh_json:get_value(<<"value">>, R),
	  wh_json:set_value(<<"rate_name">>, wh_json:get_value(<<"id">>, R), Rate)
      end || R <- Rates, matching_rate(To, Direction, RouteOptions, R)].

matching_rate(To, Direction, RouteOptions, Rate) ->
    %% need to match direction and options at some point too
    Routes = wh_json:get_value([<<"value">>, <<"routes">>], Rate),

    lists:member(Direction, wh_json:get_value([<<"value">>, <<"direction">>], Rate, [])) andalso
	options_match(RouteOptions, wh_json:get_value([<<"value">>, <<"options">>], Rate, [])) andalso
	lists:any(fun(Regex) -> re:run(To, Regex) =/= nomatch end, Routes).

%% Return true of RateA has higher weight than RateB
sort_rates(RateA, RateB) ->
    ts_util:constrain_weight(wh_json:get_value(<<"weight">>, RateA, 1)) >= ts_util:constrain_weight(wh_json:get_value(<<"weight">>, RateB, 1)).

%% match options set in Flags to options available in Rate
%% All options set in Flags must be set in Rate to be usable
%% RouteOptions come from client's DID/server/account
-spec options_match/2 :: (RouteOptions, RateOptions) -> boolean() when
      RouteOptions :: list(binary()) | json_object(),
      RateOptions :: list(binary()) | json_object().
options_match(RouteOptions, {struct, RateOptions}) ->
    options_match(RouteOptions, RateOptions);
options_match({struct, RouteOptions}, RateOptions) ->
    options_match(RouteOptions, RateOptions);
options_match([], []) ->
    true;
options_match([], _) ->
    true;
options_match(RouteOptions, RateOptions) ->
    lists:all(fun(Opt) -> props:get_value(Opt, RateOptions, false) =/= false end, RouteOptions).
