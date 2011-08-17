%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%% Utilities shared by a subset of whapps
%%% @end
%%% Created :  3 May 2011 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(whapps_util).

-export([get_db_name/1, get_db_name/2]).
-export([update_all_accounts/1]).
-export([replicate_from_accounts/2, replicate_from_account/3]).
-export([revise_whapp_views_in_accounts/1]).
-export([get_all_accounts/0, get_all_accounts/1]).
-export([get_account_by_realm/1]).
-export([get_event_type/1, put_callid/1]).
-export([get_call_termination_reason/1]).

-include_lib("whistle/include/wh_types.hrl").
-include_lib("whistle/include/wh_log.hrl").

-define(REPLICATE_ENCODING, encoded).
-define(AGG_DB, <<"accounts">>).
-define(AGG_LIST_BY_REALM, <<"accounts/listing_by_realm">>).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function will verify an account id is valid, and if so return
%% the name of the account database
%% @end
%%--------------------------------------------------------------------
-spec(get_db_name/1 :: (AccountId :: list(binary()) | json_object() | binary()) -> binary()).
-spec(get_db_name/2 :: (AccountId :: list(binary()) | binary() | json_object(), Encoding :: unencoded | encoded | raw) -> binary()).

get_db_name(Doc) -> get_db_name(Doc, unencoded).

get_db_name({struct, _}=Doc, Encoding) ->
    get_db_name([wh_json:get_value(["_id"], Doc)], Encoding);
get_db_name([AccountId], Encoding) ->
    get_db_name(AccountId, Encoding);
get_db_name(AccountId, Encoding) when not is_binary(AccountId) ->
    get_db_name(wh_util:to_binary(AccountId), Encoding);
get_db_name(<<"accounts">>, _) ->
    <<"accounts">>;
%% unencode the account db name
get_db_name(<<"account/", _/binary>>=DbName, unencoded) ->
    DbName;
get_db_name(<<"account%2F", _/binary>>=DbName, unencoded) ->
    binary:replace(DbName, <<"%2F">>, <<"/">>, [global]);
get_db_name(AccountId, unencoded) ->
    [Id1, Id2, Id3, Id4 | IdRest] = wh_util:to_list(AccountId),
    wh_util:to_binary(["account/", Id1, Id2, $/, Id3, Id4, $/, IdRest]);
%% encode the account db name
get_db_name(<<"account%2F", _/binary>>=DbName, encoded) ->
    DbName;
get_db_name(<<"account/", _/binary>>=DbName, encoded) ->
    binary:replace(DbName, <<"/">>, <<"%2F">>, [global]);
get_db_name(AccountId, encoded) when is_binary(AccountId) ->
    [Id1, Id2, Id3, Id4 | IdRest] = wh_util:to_list(AccountId),
    wh_util:to_binary(["account%2F", Id1, Id2, "%2F", Id3, Id4, "%2F", IdRest]);
%% get just the account ID from the account db name
get_db_name(<<"account%2F", AccountId/binary>>, raw) ->
    binary:replace(AccountId, <<"%2F">>, <<>>, [global]);
get_db_name(<<"account/", AccountId/binary>>, raw) ->
    binary:replace(AccountId, <<"/">>, <<>>, [global]);
get_db_name(AccountId, raw) ->
    AccountId.

%%--------------------------------------------------------------------
%% @doc
%% Update a document in each crossbar account database with the
%% file contents.  This is intended for _design docs....
%%
%% @spec update_all_accounts() -> ok | error
%% @end
%%--------------------------------------------------------------------
-spec(update_all_accounts/1 :: (File :: binary()) -> no_return()).
update_all_accounts(File) ->
    lists:foreach(fun(AccountDb) ->
                          couch_mgr:revise_doc_from_file(AccountDb, crossbar, File)
                  end, get_all_accounts(?REPLICATE_ENCODING)).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function will import every .json file found in the given
%% application priv/couchdb/views/ folder into every account
%% @end
%%--------------------------------------------------------------------
-spec(revise_whapp_views_in_accounts/1 :: (App :: atom()) -> no_return()).
revise_whapp_views_in_accounts(App) ->
    lists:foreach(fun(AccountDb) ->
                          couch_mgr:revise_views_from_folder(AccountDb, App)
                  end, get_all_accounts(?REPLICATE_ENCODING)).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function will replicate the results of the filter from each
%% account db into the target database
%% @end
%%--------------------------------------------------------------------
-spec(replicate_from_accounts/2 :: (TargetDb :: binary(), FilterDoc :: binary()) -> no_return()).
replicate_from_accounts(TargetDb, FilterDoc) when is_binary(FilterDoc) ->
    BaseReplicate = [{<<"target">>, TargetDb}
                     ,{<<"filter">>, FilterDoc}
                    ],
    couch_mgr:db_create(TargetDb),
    lists:foreach(fun(AccountDb) when TargetDb =/= AccountDb ->
                          R = couch_mgr:db_replicate([{<<"source">>, AccountDb} | BaseReplicate]),
                          ?LOG_SYS("replicate ~s to ~s using filter ~s returned ~s", [AccountDb, TargetDb, FilterDoc, element(1, R)]);
		     (_) -> ok
                  end, get_all_accounts(?REPLICATE_ENCODING)).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function will replicate the results of the filter from the
%% source database into the target database
%% @end
%%--------------------------------------------------------------------
-spec(replicate_from_account/3 :: (AccountDb :: binary(), TargetDb :: binary(), FilterDoc :: binary()) -> no_return()).
replicate_from_account(AccountDb, TargetDb, FilterDoc) when AccountDb =/= TargetDb ->
    BaseReplicate = [{<<"source">>, get_db_name(AccountDb, ?REPLICATE_ENCODING)}
                     ,{<<"target">>, TargetDb}
                     ,{<<"filter">>, FilterDoc}
                    ],
    couch_mgr:db_create(TargetDb),
    ?LOG_SYS("replicate ~s to ~s using filter ~s", [get_db_name(AccountDb, ?REPLICATE_ENCODING), TargetDb, FilterDoc]),
    case couch_mgr:db_replicate(BaseReplicate) of
	{ok, _}=OK -> ?LOG_SYS("replication succeeded"), OK;
	{error, E}=Err -> ?LOG_SYS("replication failed with ~p", [E]), Err
    end;
replicate_from_account(_,_,_) -> {error, matching_dbs}.


%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function will return a list of all account database names
%% in the requested encoding
%% @end
%%--------------------------------------------------------------------
-spec get_all_accounts/0 :: () -> [binary(),...] | [].
-spec get_all_accounts/1 :: (Encoding) -> [binary(),...] | [] when
      Encoding :: unencoded | encoded | raw.

get_all_accounts() ->
    get_all_accounts(?REPLICATE_ENCODING).

get_all_accounts(Encoding) ->
    {ok, Databases} = couch_mgr:db_info(),
    [get_db_name(Db, Encoding) || Db <- Databases
				      ,fun(<<"account/", _/binary>>) -> true;
					  (_) -> false end(Db)
    ].

%%--------------------------------------------------------------------
%% @public
%% @doc Realms are one->one with accounts.
%% @end
%%--------------------------------------------------------------------
-spec get_account_by_realm/1 :: (Realm) -> {ok, binary()}| {error, not_found} when
      Realm :: binary().
get_account_by_realm(Realm) ->
    case couch_mgr:get_results(?AGG_DB, ?AGG_LIST_BY_REALM, [{<<"key">>, Realm}]) of
	{ok, [{struct, _}=V|_]} ->
	    {ok, wh_json:get_value([<<"value">>, <<"account_db">>], V)};
	_ -> {error, not_found}
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Given an API JSON object extract the category and name into a
%% tuple for easy processing
%% @end
%%--------------------------------------------------------------------
-spec(get_event_type/1 :: (JObj :: json_object()) -> tuple(binary(), binary())).
get_event_type(JObj) ->
    { wh_json:get_value(<<"Event-Category">>, JObj), wh_json:get_value(<<"Event-Name">>, JObj) }.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Given an JSON Object extracts the Call-ID into the processes
%% dictionary, failing that the Msg-ID and finally a generic
%% @end
%%--------------------------------------------------------------------
-spec(put_callid/1 :: (JObj :: json_object()) -> no_return()).
put_callid(JObj) ->
    _ = put(callid, wh_json:get_value(<<"Call-ID">>, JObj, wh_json:get_value(<<"Msg-ID">>, JObj, <<"0000000000">>))).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Given an JSON Object for a hangup event, or bridge completion
%% this returns the cause and code for the call termination
%% @end
%%--------------------------------------------------------------------
-spec(get_call_termination_reason/1 :: (JObj :: json_object()) -> {binary(), binary()}).
get_call_termination_reason(JObj) ->
    Cause = case wh_json:get_value(<<"Application-Response">>, JObj, <<>>) of
               <<>> ->
                   wh_json:get_value(<<"Hangup-Cause">>, JObj, <<>>);
               Response ->
                   Response
           end,
    Code = wh_json:get_value(<<"Hangup-Code">>, JObj, <<>>),
    {Cause, Code}.
