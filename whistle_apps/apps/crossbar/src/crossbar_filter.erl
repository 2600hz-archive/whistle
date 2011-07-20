%%%-------------------------------------------------------------------
%%% @author Edouard Swiac <edouard@2600hz.org>
%%% @copyright (C) 2010-2011 VoIP INC
%%% @doc
%%%
%%% @end
%%% Created : 8 Dec 2011 by Edouard Swiac <edouard@2600hz.org>
%%%-------------------------------------------------------------------
-module(crossbar_filter).

-export([filter_on_query_string/3]).

-include("crossbar.hrl").

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Attempt to load list of Doc ID from the crossbar_listing view,
%% filtered on the query string params
%% @end
%%--------------------------------------------------------------------
-spec filter_on_query_string/3 :: (DbName :: binary(), View :: binary(), QueryParams :: proplist()) -> [binary(),...] | [].
filter_on_query_string(DbName, View, QueryParams) ->
    QueryParams1 = [{list_to_binary(K), list_to_binary(V)} || {K, V} <- QueryParams], %% qs from wm are strings
    {ok, AllDocs} = couch_mgr:get_results(DbName, View, [{<<"include_docs">>, true}]),
    UnfilteredDocs = [wh_json:get_value(<<"doc">>, UnfilteredDoc, ?EMPTY_JSON_OBJECT) || UnfilteredDoc <- AllDocs],
    [wh_json:get_value(<<"_id">>, Doc) || Doc <- UnfilteredDocs, filter_doc(Doc, QueryParams1)].

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Returns true if all of the requested props are found, false if one is not found
%% @end
%%--------------------------------------------------------------------
-spec filter_doc/2 :: (Doc, Props) -> boolean() when
      Doc :: json_object(),
      Props :: proplist().
filter_doc(Doc, Props) ->
    Result = [true || {Key, Val} <- Props, filter_prop(Doc, Key, Val)],
    (Result =/= [] andalso lists:all(fun(Term) -> Term end, Result)).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Returns true or false if the prop is found inside the doc
%% @end
%%--------------------------------------------------------------------
-spec filter_prop/3 :: (Doc, Key, Val) -> boolean() when
      Doc :: json_object(),
      Key :: binary(),
      Val :: term().
filter_prop(Doc, <<"filter_", Key/binary>>, Val) ->
    wh_json:get_value(Key, Doc) == Val;
filter_prop(Doc, <<"created_from">>, Val) ->
    whistle_util:to_integer(wh_json:get_value(<<"pvt_created">>, Doc)) >= whistle_util:to_integer(Val);
filter_prop(Doc, <<"created_to">>, Val) ->
    whistle_util:to_integer(wh_json:get_value(<<"pvt_created">>, Doc)) =< whistle_util:to_integer(Val);
filter_prop(Doc, <<"modified_from">>, Val) ->
    whistle_util:to_integer(wh_json:get_value(<<"pvt_modified">>, Doc)) >= whistle_util:to_integer(Val);
filter_prop(Doc, <<"modified_to">>, Val) ->
    whistle_util:to_integer(wh_json:get_value(<<"pvt_modified">>, Doc)) =< whistle_util:to_integer(Val);
filter_prop(_, _, _) ->
    false.

%% next filters to implement are to range on a prop
%% build_filter_options(<<"range_", Param/binary, "_from">>) -> nyi.
%% build_filter_options(<<"range_", Param/binary, "_to">>) -> nyi.
