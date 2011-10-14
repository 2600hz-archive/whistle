%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%% Handles authentication requests, responses, queue bindings
%%% @end
%%% Created : 14 Oct 2011 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(wapi_authn).

-export([req/1, resp/1, req_v/1, resp_v/1, bind_q/2, unbind_q/1]).

-include("../wh_api.hrl").

-define(AUTHN_REQ_HEADERS, [<<"Msg-ID">>, <<"To">>, <<"From">>, <<"Orig-IP">>
				, <<"Auth-User">>, <<"Auth-Realm">>]).
-define(OPTIONAL_AUTHN_REQ_HEADERS, [<<"Method">>]).
-define(AUTHN_REQ_VALUES, [{<<"Event-Category">>, <<"directory">>}
			   ,{<<"Event-Name">>, <<"authn_req">>}
			  ]).
-define(AUTHN_REQ_TYPES, [{<<"Msg-ID">>, fun is_binary/1}
			  ,{<<"To">>, fun is_binary/1}
			  ,{<<"From">>, fun is_binary/1}
			  ,{<<"Orig-IP">>, fun is_binary/1}
			  ,{<<"Auth-User">>, fun is_binary/1}
			  ,{<<"Auth-Realm">>, fun is_binary/1}
			 ]).

%% Authentication Responses
-define(AUTHN_RESP_HEADERS, [<<"Msg-ID">>, <<"Auth-Method">>, <<"Auth-Password">>]).
-define(OPTIONAL_AUTHN_RESP_HEADERS, [<<"Tenant-ID">>, <<"Access-Group">>, <<"Custom-Channel-Vars">>]).
-define(AUTHN_RESP_VALUES, [{<<"Event-Category">>, <<"directory">>}
			   ,{<<"Event-Name">>, <<"authn_resp">>}
			   ,{<<"Auth-Method">>, [<<"password">>, <<"ip">>, <<"a1-hash">>, <<"error">>]}
			 ]).
-define(AUTHN_RESP_TYPES, [{<<"Msg-ID">>, fun is_binary/1}
			  ,{<<"Auth-Password">>, fun is_binary/1}
			  ,{<<"Custom-Channel-Vars">>, ?IS_JSON_OBJECT}
			  ,{<<"Access-Group">>, fun is_binary/1}
			  ,{<<"Tenant-ID">>, fun is_binary/1}
			 ]).

-spec req/1 :: (proplist() | json_object()) -> {'ok', iolist()} | {'error', string()}.
req(Prop) when is_list(Prop) ->
        case req_v(Prop) of
	    true -> wh_api:build_message(Prop, ?AUTHN_REQ_HEADERS, ?OPTIONAL_AUTHN_REQ_HEADERS);
	    false -> {error, "Proplist failed validation for authn_req"}
    end;
req(JObj) ->
    req(wh_json:to_proplist(JObj)).

-spec req_v/1 :: (proplist() | json_object()) -> boolean().
req_v(Prop) when is_list(Prop) ->
    wh_api:validate(Prop, ?AUTHN_REQ_HEADERS, ?AUTHN_REQ_VALUES, ?AUTHN_REQ_TYPES);
req_v(JObj) ->
    req_v(wh_json:to_proplist(JObj)).

%%--------------------------------------------------------------------
%% @doc Authentication Response - see wiki
%% Takes proplist, creates JSON string or error
%% @end
%%--------------------------------------------------------------------
-spec resp/1 :: (proplist() | json_object()) -> {'ok', iolist()} | {'error', string()}.
resp(Prop) when is_list(Prop) ->
    case resp_v(Prop) of
	true -> wh_api:build_message(Prop, ?AUTHN_RESP_HEADERS, ?OPTIONAL_AUTHN_RESP_HEADERS);
	false -> {error, "Proplist failed validation for authn_resp"}
    end;
resp(JObj) ->
    resp(wh_json:to_proplist(JObj)).

-spec resp_v/1 :: (proplist() | json_object()) -> boolean().
resp_v(Prop) when is_list(Prop) ->
    wh_api:validate(Prop, ?AUTHN_RESP_HEADERS, ?AUTHN_RESP_VALUES, ?AUTHN_RESP_TYPES);
resp_v(JObj) ->
    resp_v(wh_json:to_proplist(JObj)).

bind_q(_,_) ->
    ok.

unbind_q(_) ->
    ok.
