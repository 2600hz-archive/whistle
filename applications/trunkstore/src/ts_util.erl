%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2010, James Aimonetti
%%% @doc
%%% utility functions for Trunkstore
%%% @end
%%% Created : 24 Nov 2010 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(ts_util).

-export([find_ip/1, filter_active_calls/2]).

-include("ts.hrl").
-include_lib("kernel/include/inet.hrl"). %% for hostent record, used in find_ip/1

-spec(find_ip/1 :: (Domain :: binary() | list()) -> list()).
find_ip(Domain) when is_binary(Domain) ->
    find_ip(binary_to_list(Domain));
find_ip(Domain) when is_list(Domain) ->
    case inet:gethostbyname(Domain, inet) of %% eventually we'll want to support both IPv4 and IPv6
	{error, _Err} ->
	    Domain;
	{ok, Hostent} when is_record(Hostent, hostent) ->
	    case Hostent#hostent.h_addr_list of
		[] -> Domain;
		[Addr | _Rest] -> inet_parse:ntoa(Addr)
	    end
    end.

%% FilterOn: CallID | flat_rate | per_min
%% Remove active call entries based on what Filter criteria is passed in
-spec(filter_active_calls/2 :: (FilterOn :: binary() | flat_rate | per_min, ActiveCalls :: active_calls()) -> active_calls()).
filter_active_calls(flat_rate, ActiveCalls) ->
    lists:filter(fun({_,flat_rate}) -> false; (_) -> true end, ActiveCalls);
filter_active_calls(per_min, ActiveCalls) ->
    lists:filter(fun({_,per_min}) -> false; (_) -> true end, ActiveCalls);
filter_active_calls(CallID, ActiveCalls) ->
    lists:filter(fun({CallID1,_}) when CallID =:= CallID1 -> false;
		    (CallID1) when CallID =:= CallID1 -> false;
		    (_) -> true end, ActiveCalls).
