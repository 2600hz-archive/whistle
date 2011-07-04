%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2011 VMware, Inc.  All rights reserved.
%%

-module(rabbit_sasl_report_file_h).

-behaviour(gen_event).

-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2,
         code_change/3]).

%% rabbit_sasl_report_file_h is a wrapper around the sasl_report_file_h
%% module because the original's init/1 does not match properly
%% with the result of closing the old handler when swapping handlers.
%% The first init/1 additionally allows for simple log rotation
%% when the suffix is not the empty string.

%% Used only when swapping handlers and performing
%% log rotation
init({{File, Suffix}, []}) ->
    case rabbit_misc:append_file(File, Suffix) of
        ok -> ok;
        {error, Error} ->
            rabbit_log:error("Failed to append contents of "
                             "sasl log file '~s' to '~s':~n~p~n",
                             [File, [File, Suffix], Error])
    end,
    init(File);
%% Used only when swapping handlers and the original handler
%% failed to terminate or was never installed
init({{File, _}, error}) ->
    init(File);
%% Used only when swapping handlers without
%% doing any log rotation
init({File, []}) ->
    init(File);
init({File, _Type} = FileInfo) ->
    rabbit_misc:ensure_parent_dirs_exist(File),
    sasl_report_file_h:init(FileInfo);
init(File) ->
    rabbit_misc:ensure_parent_dirs_exist(File),
    sasl_report_file_h:init({File, sasl_error_logger_type()}).

handle_event(Event, State) ->
    sasl_report_file_h:handle_event(Event, State).

handle_info(Event, State) ->
    sasl_report_file_h:handle_info(Event, State).

handle_call(Event, State) ->
    sasl_report_file_h:handle_call(Event, State).

terminate(Reason, State) ->
    sasl_report_file_h:terminate(Reason, State).

code_change(_OldVsn, State, _Extra) ->
    %% There is no sasl_report_file_h:code_change/3
    {ok, State}.

%%----------------------------------------------------------------------

sasl_error_logger_type() ->
    case application:get_env(sasl, errlog_type) of
        {ok, error}    -> error;
        {ok, progress} -> progress;
        {ok, all}      -> all;
        {ok, Bad}      -> throw({error, {wrong_errlog_type, Bad}});
        _              -> all
    end.
