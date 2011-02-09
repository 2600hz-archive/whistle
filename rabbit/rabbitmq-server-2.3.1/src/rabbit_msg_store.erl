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

-module(rabbit_msg_store).

-behaviour(gen_server2).

-export([start_link/4, successfully_recovered_state/1,
         client_init/4, client_terminate/1, client_delete_and_terminate/1,
         client_ref/1, close_all_indicated/1,
         write/3, read/2, contains/2, remove/2, release/2, sync/3]).

-export([sync/1, set_maximum_since_use/2,
         has_readers/2, combine_files/3, delete_file/2]). %% internal

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, prioritise_call/3, prioritise_cast/2]).

%%----------------------------------------------------------------------------

-include("rabbit_msg_store.hrl").

-define(SYNC_INTERVAL,  5).   %% milliseconds
-define(CLEAN_FILENAME, "clean.dot").
-define(FILE_SUMMARY_FILENAME, "file_summary.ets").

-define(BINARY_MODE,     [raw, binary]).
-define(READ_MODE,       [read]).
-define(READ_AHEAD_MODE, [read_ahead | ?READ_MODE]).
-define(WRITE_MODE,      [write]).

-define(FILE_EXTENSION,        ".rdq").
-define(FILE_EXTENSION_TMP,    ".rdt").

-define(HANDLE_CACHE_BUFFER_SIZE, 1048576). %% 1MB

%%----------------------------------------------------------------------------

-record(msstate,
        { dir,                    %% store directory
          index_module,           %% the module for index ops
          index_state,            %% where are messages?
          current_file,           %% current file name as number
          current_file_handle,    %% current file handle since the last fsync?
          file_handle_cache,      %% file handle cache
          on_sync,                %% pending sync requests
          sync_timer_ref,         %% TRef for our interval timer
          sum_valid_data,         %% sum of valid data in all files
          sum_file_size,          %% sum of file sizes
          pending_gc_completion,  %% things to do once GC completes
          gc_pid,                 %% pid of our GC
          file_handles_ets,       %% tid of the shared file handles table
          file_summary_ets,       %% tid of the file summary table
          dedup_cache_ets,        %% tid of dedup cache table
          cur_file_cache_ets,     %% tid of current file cache table
          dying_clients,          %% set of dying clients
          clients,                %% map of references of all registered clients
                                  %% to callbacks
          successfully_recovered, %% boolean: did we recover state?
          file_size_limit,        %% how big are our files allowed to get?
          cref_to_guids           %% client ref to synced messages mapping
         }).

-record(client_msstate,
        { server,
          client_ref,
          file_handle_cache,
          index_state,
          index_module,
          dir,
          gc_pid,
          file_handles_ets,
          file_summary_ets,
          dedup_cache_ets,
          cur_file_cache_ets
         }).

-record(file_summary,
        {file, valid_total_size, left, right, file_size, locked, readers}).

-record(gc_state,
        { dir,
          index_module,
          index_state,
          file_summary_ets,
          file_handles_ets,
          msg_store
        }).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-export_type([gc_state/0, file_num/0]).

-type(gc_state() :: #gc_state { dir              :: file:filename(),
                                index_module     :: atom(),
                                index_state      :: any(),
                                file_summary_ets :: ets:tid(),
                                file_handles_ets :: ets:tid(),
                                msg_store        :: server()
                              }).

-type(server() :: pid() | atom()).
-type(client_ref() :: binary()).
-type(file_num() :: non_neg_integer()).
-type(client_msstate() :: #client_msstate {
                      server             :: server(),
                      client_ref         :: client_ref(),
                      file_handle_cache  :: dict(),
                      index_state        :: any(),
                      index_module       :: atom(),
                      dir                :: file:filename(),
                      gc_pid             :: pid(),
                      file_handles_ets   :: ets:tid(),
                      file_summary_ets   :: ets:tid(),
                      dedup_cache_ets    :: ets:tid(),
                      cur_file_cache_ets :: ets:tid()}).
-type(startup_fun_state() ::
        {(fun ((A) -> 'finished' | {rabbit_guid:guid(), non_neg_integer(), A})),
         A}).
-type(maybe_guid_fun() :: 'undefined' | fun ((gb_set()) -> any())).
-type(maybe_close_fds_fun() :: 'undefined' | fun (() -> 'ok')).
-type(deletion_thunk() :: fun (() -> boolean())).

-spec(start_link/4 ::
        (atom(), file:filename(), [binary()] | 'undefined',
         startup_fun_state()) -> rabbit_types:ok_pid_or_error()).
-spec(successfully_recovered_state/1 :: (server()) -> boolean()).
-spec(client_init/4 :: (server(), client_ref(), maybe_guid_fun(),
                        maybe_close_fds_fun()) -> client_msstate()).
-spec(client_terminate/1 :: (client_msstate()) -> 'ok').
-spec(client_delete_and_terminate/1 :: (client_msstate()) -> 'ok').
-spec(client_ref/1 :: (client_msstate()) -> client_ref()).
-spec(write/3 :: (rabbit_guid:guid(), msg(), client_msstate()) -> 'ok').
-spec(read/2 :: (rabbit_guid:guid(), client_msstate()) ->
             {rabbit_types:ok(msg()) | 'not_found', client_msstate()}).
-spec(contains/2 :: (rabbit_guid:guid(), client_msstate()) -> boolean()).
-spec(remove/2 :: ([rabbit_guid:guid()], client_msstate()) -> 'ok').
-spec(release/2 :: ([rabbit_guid:guid()], client_msstate()) -> 'ok').
-spec(sync/3 :: ([rabbit_guid:guid()], fun (() -> any()), client_msstate()) ->
             'ok').

-spec(sync/1 :: (server()) -> 'ok').
-spec(set_maximum_since_use/2 :: (server(), non_neg_integer()) -> 'ok').
-spec(has_readers/2 :: (non_neg_integer(), gc_state()) -> boolean()).
-spec(combine_files/3 :: (non_neg_integer(), non_neg_integer(), gc_state()) ->
                              deletion_thunk()).
-spec(delete_file/2 :: (non_neg_integer(), gc_state()) -> deletion_thunk()).

-endif.

%%----------------------------------------------------------------------------

%% We run GC whenever (garbage / sum_file_size) > ?GARBAGE_FRACTION
%% It is not recommended to set this to < 0.5
-define(GARBAGE_FRACTION,      0.5).

%% The components:
%%
%% Index: this is a mapping from Guid to #msg_location{}:
%%        {Guid, RefCount, File, Offset, TotalSize}
%%        By default, it's in ets, but it's also pluggable.
%% FileSummary: this is an ets table which maps File to #file_summary{}:
%%        {File, ValidTotalSize, Left, Right, FileSize, Locked, Readers}
%%
%% The basic idea is that messages are appended to the current file up
%% until that file becomes too big (> file_size_limit). At that point,
%% the file is closed and a new file is created on the _right_ of the
%% old file which is used for new messages. Files are named
%% numerically ascending, thus the file with the lowest name is the
%% eldest file.
%%
%% We need to keep track of which messages are in which files (this is
%% the Index); how much useful data is in each file and which files
%% are on the left and right of each other. This is the purpose of the
%% FileSummary ets table.
%%
%% As messages are removed from files, holes appear in these
%% files. The field ValidTotalSize contains the total amount of useful
%% data left in the file. This is needed for garbage collection.
%%
%% When we discover that a file is now empty, we delete it. When we
%% discover that it can be combined with the useful data in either its
%% left or right neighbour, and overall, across all the files, we have
%% ((the amount of garbage) / (the sum of all file sizes)) >
%% ?GARBAGE_FRACTION, we start a garbage collection run concurrently,
%% which will compact the two files together. This keeps disk
%% utilisation high and aids performance. We deliberately do this
%% lazily in order to prevent doing GC on files which are soon to be
%% emptied (and hence deleted) soon.
%%
%% Given the compaction between two files, the left file (i.e. elder
%% file) is considered the ultimate destination for the good data in
%% the right file. If necessary, the good data in the left file which
%% is fragmented throughout the file is written out to a temporary
%% file, then read back in to form a contiguous chunk of good data at
%% the start of the left file. Thus the left file is garbage collected
%% and compacted. Then the good data from the right file is copied
%% onto the end of the left file. Index and FileSummary tables are
%% updated.
%%
%% On non-clean startup, we scan the files we discover, dealing with
%% the possibilites of a crash having occured during a compaction
%% (this consists of tidyup - the compaction is deliberately designed
%% such that data is duplicated on disk rather than risking it being
%% lost), and rebuild the FileSummary ets table and Index.
%%
%% So, with this design, messages move to the left. Eventually, they
%% should end up in a contiguous block on the left and are then never
%% rewritten. But this isn't quite the case. If in a file there is one
%% message that is being ignored, for some reason, and messages in the
%% file to the right and in the current block are being read all the
%% time then it will repeatedly be the case that the good data from
%% both files can be combined and will be written out to a new
%% file. Whenever this happens, our shunned message will be rewritten.
%%
%% So, provided that we combine messages in the right order,
%% (i.e. left file, bottom to top, right file, bottom to top),
%% eventually our shunned message will end up at the bottom of the
%% left file. The compaction/combining algorithm is smart enough to
%% read in good data from the left file that is scattered throughout
%% (i.e. C and D in the below diagram), then truncate the file to just
%% above B (i.e. truncate to the limit of the good contiguous region
%% at the start of the file), then write C and D on top and then write
%% E, F and G from the right file on top. Thus contiguous blocks of
%% good data at the bottom of files are not rewritten.
%%
%% +-------+    +-------+         +-------+
%% |   X   |    |   G   |         |   G   |
%% +-------+    +-------+         +-------+
%% |   D   |    |   X   |         |   F   |
%% +-------+    +-------+         +-------+
%% |   X   |    |   X   |         |   E   |
%% +-------+    +-------+         +-------+
%% |   C   |    |   F   |   ===>  |   D   |
%% +-------+    +-------+         +-------+
%% |   X   |    |   X   |         |   C   |
%% +-------+    +-------+         +-------+
%% |   B   |    |   X   |         |   B   |
%% +-------+    +-------+         +-------+
%% |   A   |    |   E   |         |   A   |
%% +-------+    +-------+         +-------+
%%   left         right             left
%%
%% From this reasoning, we do have a bound on the number of times the
%% message is rewritten. From when it is inserted, there can be no
%% files inserted between it and the head of the queue, and the worst
%% case is that everytime it is rewritten, it moves one position lower
%% in the file (for it to stay at the same position requires that
%% there are no holes beneath it, which means truncate would be used
%% and so it would not be rewritten at all). Thus this seems to
%% suggest the limit is the number of messages ahead of it in the
%% queue, though it's likely that that's pessimistic, given the
%% requirements for compaction/combination of files.
%%
%% The other property is that we have is the bound on the lowest
%% utilisation, which should be 50% - worst case is that all files are
%% fractionally over half full and can't be combined (equivalent is
%% alternating full files and files with only one tiny message in
%% them).
%%
%% Messages are reference-counted. When a message with the same guid
%% is written several times we only store it once, and only remove it
%% from the store when it has been removed the same number of times.
%%
%% The reference counts do not persist. Therefore the initialisation
%% function must be provided with a generator that produces ref count
%% deltas for all recovered messages. This is only used on startup
%% when the shutdown was non-clean.
%%
%% Read messages with a reference count greater than one are entered
%% into a message cache. The purpose of the cache is not especially
%% performance, though it can help there too, but prevention of memory
%% explosion. It ensures that as messages with a high reference count
%% are read from several processes they are read back as the same
%% binary object rather than multiples of identical binary
%% objects.
%%
%% Reads can be performed directly by clients without calling to the
%% server. This is safe because multiple file handles can be used to
%% read files. However, locking is used by the concurrent GC to make
%% sure that reads are not attempted from files which are in the
%% process of being garbage collected.
%%
%% When a message is removed, its reference count is decremented. Even
%% if the reference count becomes 0, its entry is not removed. This is
%% because in the event of the same message being sent to several
%% different queues, there is the possibility of one queue writing and
%% removing the message before other queues write it at all. Thus
%% accomodating 0-reference counts allows us to avoid unnecessary
%% writes here. Of course, there are complications: the file to which
%% the message has already been written could be locked pending
%% deletion or GC, which means we have to rewrite the message as the
%% original copy will now be lost.
%%
%% The server automatically defers reads, removes and contains calls
%% that occur which refer to files which are currently being
%% GC'd. Contains calls are only deferred in order to ensure they do
%% not overtake removes.
%%
%% The current file to which messages are being written has a
%% write-back cache. This is written to immediately by clients and can
%% be read from by clients too. This means that there are only ever
%% writes made to the current file, thus eliminating delays due to
%% flushing write buffers in order to be able to safely read from the
%% current file. The one exception to this is that on start up, the
%% cache is not populated with msgs found in the current file, and
%% thus in this case only, reads may have to come from the file
%% itself. The effect of this is that even if the msg_store process is
%% heavily overloaded, clients can still write and read messages with
%% very low latency and not block at all.
%%
%% Clients of the msg_store are required to register before using the
%% msg_store. This provides them with the necessary client-side state
%% to allow them to directly access the various caches and files. When
%% they terminate, they should deregister. They can do this by calling
%% either client_terminate/1 or client_delete_and_terminate/1. The
%% differences are: (a) client_terminate is synchronous. As a result,
%% if the msg_store is badly overloaded and has lots of in-flight
%% writes and removes to process, this will take some time to
%% return. However, once it does return, you can be sure that all the
%% actions you've issued to the msg_store have been processed. (b) Not
%% only is client_delete_and_terminate/1 asynchronous, but it also
%% permits writes and subsequent removes from the current
%% (terminating) client which are still in flight to be safely
%% ignored. Thus from the point of view of the msg_store itself, and
%% all from the same client:
%%
%% (T) = termination; (WN) = write of msg N; (RN) = remove of msg N
%% --> W1, W2, W1, R1, T, W3, R2, W2, R1, R2, R3, W4 -->
%%
%% The client obviously sent T after all the other messages (up to
%% W4), but because the msg_store prioritises messages, the T can be
%% promoted and thus received early.
%%
%% Thus at the point of the msg_store receiving T, we have messages 1
%% and 2 with a refcount of 1. After T, W3 will be ignored because
%% it's an unknown message, as will R3, and W4. W2, R1 and R2 won't be
%% ignored because the messages that they refer to were already known
%% to the msg_store prior to T. However, it can be a little more
%% complex: after the first R2, the refcount of msg 2 is 0. At that
%% point, if a GC occurs or file deletion, msg 2 could vanish, which
%% would then mean that the subsequent W2 and R2 are then ignored.
%%
%% The use case then for client_delete_and_terminate/1 is if the
%% client wishes to remove everything it's written to the msg_store:
%% it issues removes for all messages it's written and not removed,
%% and then calls client_delete_and_terminate/1. At that point, any
%% in-flight writes (and subsequent removes) can be ignored, but
%% removes and writes for messages the msg_store already knows about
%% will continue to be processed normally (which will normally just
%% involve modifying the reference count, which is fast). Thus we save
%% disk bandwidth for writes which are going to be immediately removed
%% again by the the terminating client.
%%
%% We use a separate set to keep track of the dying clients in order
%% to keep that set, which is inspected on every write and remove, as
%% small as possible. Inspecting the set of all clients would degrade
%% performance with many healthy clients and few, if any, dying
%% clients, which is the typical case.
%%
%% For notes on Clean Shutdown and startup, see documentation in
%% variable_queue.

%%----------------------------------------------------------------------------
%% public API
%%----------------------------------------------------------------------------

start_link(Server, Dir, ClientRefs, StartupFunState) ->
    gen_server2:start_link({local, Server}, ?MODULE,
                           [Server, Dir, ClientRefs, StartupFunState],
                           [{timeout, infinity}]).

successfully_recovered_state(Server) ->
    gen_server2:call(Server, successfully_recovered_state, infinity).

client_init(Server, Ref, MsgOnDiskFun, CloseFDsFun) ->
    {IState, IModule, Dir, GCPid,
     FileHandlesEts, FileSummaryEts, DedupCacheEts, CurFileCacheEts} =
        gen_server2:call(
          Server, {new_client_state, Ref, MsgOnDiskFun, CloseFDsFun}, infinity),
    #client_msstate { server             = Server,
                      client_ref         = Ref,
                      file_handle_cache  = dict:new(),
                      index_state        = IState,
                      index_module       = IModule,
                      dir                = Dir,
                      gc_pid             = GCPid,
                      file_handles_ets   = FileHandlesEts,
                      file_summary_ets   = FileSummaryEts,
                      dedup_cache_ets    = DedupCacheEts,
                      cur_file_cache_ets = CurFileCacheEts }.

client_terminate(CState = #client_msstate { client_ref = Ref }) ->
    close_all_handles(CState),
    ok = server_call(CState, {client_terminate, Ref}).

client_delete_and_terminate(CState = #client_msstate { client_ref = Ref }) ->
    close_all_handles(CState),
    ok = server_cast(CState, {client_dying, Ref}),
    ok = server_cast(CState, {client_delete, Ref}).

client_ref(#client_msstate { client_ref = Ref }) -> Ref.

write(Guid, Msg,
      CState = #client_msstate { cur_file_cache_ets = CurFileCacheEts,
                                 client_ref         = CRef }) ->
    ok = update_msg_cache(CurFileCacheEts, Guid, Msg),
    ok = server_cast(CState, {write, CRef, Guid}).

read(Guid,
     CState = #client_msstate { dedup_cache_ets    = DedupCacheEts,
                                cur_file_cache_ets = CurFileCacheEts }) ->
    %% 1. Check the dedup cache
    case fetch_and_increment_cache(DedupCacheEts, Guid) of
        not_found ->
            %% 2. Check the cur file cache
            case ets:lookup(CurFileCacheEts, Guid) of
                [] ->
                    Defer = fun() ->
                                    {server_call(CState, {read, Guid}), CState}
                            end,
                    case index_lookup_positive_ref_count(Guid, CState) of
                        not_found   -> Defer();
                        MsgLocation -> client_read1(MsgLocation, Defer, CState)
                    end;
                [{Guid, Msg, _CacheRefCount}] ->
                    %% Although we've found it, we don't know the
                    %% refcount, so can't insert into dedup cache
                    {{ok, Msg}, CState}
            end;
        Msg ->
            {{ok, Msg}, CState}
    end.

contains(Guid, CState) -> server_call(CState, {contains, Guid}).
remove([],    _CState) -> ok;
remove(Guids, CState = #client_msstate { client_ref = CRef }) ->
    server_cast(CState, {remove, CRef, Guids}).
release([],   _CState) -> ok;
release(Guids, CState) -> server_cast(CState, {release, Guids}).
sync(Guids, K, CState) -> server_cast(CState, {sync, Guids, K}).

sync(Server) ->
    gen_server2:cast(Server, sync).

set_maximum_since_use(Server, Age) ->
    gen_server2:cast(Server, {set_maximum_since_use, Age}).

%%----------------------------------------------------------------------------
%% Client-side-only helpers
%%----------------------------------------------------------------------------

server_call(#client_msstate { server = Server }, Msg) ->
    gen_server2:call(Server, Msg, infinity).

server_cast(#client_msstate { server = Server }, Msg) ->
    gen_server2:cast(Server, Msg).

client_read1(#msg_location { guid = Guid, file = File } = MsgLocation, Defer,
             CState = #client_msstate { file_summary_ets = FileSummaryEts }) ->
    case ets:lookup(FileSummaryEts, File) of
        [] -> %% File has been GC'd and no longer exists. Go around again.
            read(Guid, CState);
        [#file_summary { locked = Locked, right = Right }] ->
            client_read2(Locked, Right, MsgLocation, Defer, CState)
    end.

client_read2(false, undefined, _MsgLocation, Defer, _CState) ->
    %% Although we've already checked both caches and not found the
    %% message there, the message is apparently in the
    %% current_file. We can only arrive here if we are trying to read
    %% a message which we have not written, which is very odd, so just
    %% defer.
    %%
    %% OR, on startup, the cur_file_cache is not populated with the
    %% contents of the current file, thus reads from the current file
    %% will end up here and will need to be deferred.
    Defer();
client_read2(true, _Right, _MsgLocation, Defer, _CState) ->
    %% Of course, in the mean time, the GC could have run and our msg
    %% is actually in a different file, unlocked. However, defering is
    %% the safest and simplest thing to do.
    Defer();
client_read2(false, _Right,
             MsgLocation = #msg_location { guid = Guid, file = File },
             Defer,
             CState = #client_msstate { file_summary_ets = FileSummaryEts }) ->
    %% It's entirely possible that everything we're doing from here on
    %% is for the wrong file, or a non-existent file, as a GC may have
    %% finished.
    safe_ets_update_counter(
      FileSummaryEts, File, {#file_summary.readers, +1},
      fun (_) -> client_read3(MsgLocation, Defer, CState) end,
      fun () -> read(Guid, CState) end).

client_read3(#msg_location { guid = Guid, file = File }, Defer,
             CState = #client_msstate { file_handles_ets = FileHandlesEts,
                                        file_summary_ets = FileSummaryEts,
                                        dedup_cache_ets  = DedupCacheEts,
                                        gc_pid           = GCPid,
                                        client_ref       = Ref }) ->
    Release =
        fun() -> ok = case ets:update_counter(FileSummaryEts, File,
                                              {#file_summary.readers, -1}) of
                          0 -> case ets:lookup(FileSummaryEts, File) of
                                   [#file_summary { locked = true }] ->
                                       rabbit_msg_store_gc:no_readers(
                                         GCPid, File);
                                   _ -> ok
                               end;
                          _ -> ok
                      end
        end,
    %% If a GC involving the file hasn't already started, it won't
    %% start now. Need to check again to see if we've been locked in
    %% the meantime, between lookup and update_counter (thus GC
    %% started before our +1. In fact, it could have finished by now
    %% too).
    case ets:lookup(FileSummaryEts, File) of
        [] -> %% GC has deleted our file, just go round again.
            read(Guid, CState);
        [#file_summary { locked = true }] ->
            %% If we get a badarg here, then the GC has finished and
            %% deleted our file. Try going around again. Otherwise,
            %% just defer.
            %%
            %% badarg scenario: we lookup, msg_store locks, GC starts,
            %% GC ends, we +1 readers, msg_store ets:deletes (and
            %% unlocks the dest)
            try Release(),
                Defer()
            catch error:badarg -> read(Guid, CState)
            end;
        [#file_summary { locked = false }] ->
            %% Ok, we're definitely safe to continue - a GC involving
            %% the file cannot start up now, and isn't running, so
            %% nothing will tell us from now on to close the handle if
            %% it's already open.
            %%
            %% Finally, we need to recheck that the msg is still at
            %% the same place - it's possible an entire GC ran between
            %% us doing the lookup and the +1 on the readers. (Same as
            %% badarg scenario above, but we don't have a missing file
            %% - we just have the /wrong/ file).
            case index_lookup(Guid, CState) of
                #msg_location { file = File } = MsgLocation ->
                    %% Still the same file.
                    {ok, CState1} = close_all_indicated(CState),
                    %% We are now guaranteed that the mark_handle_open
                    %% call will either insert_new correctly, or will
                    %% fail, but find the value is open, not close.
                    mark_handle_open(FileHandlesEts, File, Ref),
                    %% Could the msg_store now mark the file to be
                    %% closed? No: marks for closing are issued only
                    %% when the msg_store has locked the file.
                    {Msg, CState2} = %% This will never be the current file
                        read_from_disk(MsgLocation, CState1, DedupCacheEts),
                    Release(), %% this MUST NOT fail with badarg
                    {{ok, Msg}, CState2};
                #msg_location {} = MsgLocation -> %% different file!
                    Release(), %% this MUST NOT fail with badarg
                    client_read1(MsgLocation, Defer, CState);
                not_found -> %% it seems not to exist. Defer, just to be sure.
                    try Release() %% this can badarg, same as locked case, above
                    catch error:badarg -> ok
                    end,
                    Defer()
            end
    end.

clear_client(CRef, State = #msstate { cref_to_guids = CTG,
                                      dying_clients = DyingClients }) ->
    State #msstate { cref_to_guids = dict:erase(CRef, CTG),
                     dying_clients = sets:del_element(CRef, DyingClients) }.


%%----------------------------------------------------------------------------
%% gen_server callbacks
%%----------------------------------------------------------------------------

init([Server, BaseDir, ClientRefs, StartupFunState]) ->
    process_flag(trap_exit, true),

    ok = file_handle_cache:register_callback(?MODULE, set_maximum_since_use,
                                             [self()]),

    Dir = filename:join(BaseDir, atom_to_list(Server)),

    {ok, IndexModule} = application:get_env(msg_store_index_module),
    rabbit_log:info("~w: using ~p to provide index~n", [Server, IndexModule]),

    AttemptFileSummaryRecovery =
        case ClientRefs of
            undefined -> ok = rabbit_misc:recursive_delete([Dir]),
                         ok = filelib:ensure_dir(filename:join(Dir, "nothing")),
                         false;
            _         -> ok = filelib:ensure_dir(filename:join(Dir, "nothing")),
                         recover_crashed_compactions(Dir)
        end,

    %% if we found crashed compactions we trust neither the
    %% file_summary nor the location index. Note the file_summary is
    %% left empty here if it can't be recovered.
    {FileSummaryRecovered, FileSummaryEts} =
        recover_file_summary(AttemptFileSummaryRecovery, Dir),

    {CleanShutdown, IndexState, ClientRefs1} =
        recover_index_and_client_refs(IndexModule, FileSummaryRecovered,
                                      ClientRefs, Dir, Server),
    Clients = dict:from_list(
                [{CRef, {undefined, undefined}} || CRef <- ClientRefs1]),
    %% CleanShutdown => msg location index and file_summary both
    %% recovered correctly.
    true = case {FileSummaryRecovered, CleanShutdown} of
               {true, false} -> ets:delete_all_objects(FileSummaryEts);
               _             -> true
           end,
    %% CleanShutdown <=> msg location index and file_summary both
    %% recovered correctly.

    DedupCacheEts   = ets:new(rabbit_msg_store_dedup_cache, [set, public]),
    FileHandlesEts  = ets:new(rabbit_msg_store_shared_file_handles,
                              [ordered_set, public]),
    CurFileCacheEts = ets:new(rabbit_msg_store_cur_file, [set, public]),

    {ok, FileSizeLimit} = application:get_env(msg_store_file_size_limit),

    State = #msstate { dir                    = Dir,
                       index_module           = IndexModule,
                       index_state            = IndexState,
                       current_file           = 0,
                       current_file_handle    = undefined,
                       file_handle_cache      = dict:new(),
                       on_sync                = [],
                       sync_timer_ref         = undefined,
                       sum_valid_data         = 0,
                       sum_file_size          = 0,
                       pending_gc_completion  = orddict:new(),
                       gc_pid                 = undefined,
                       file_handles_ets       = FileHandlesEts,
                       file_summary_ets       = FileSummaryEts,
                       dedup_cache_ets        = DedupCacheEts,
                       cur_file_cache_ets     = CurFileCacheEts,
                       dying_clients          = sets:new(),
                       clients                = Clients,
                       successfully_recovered = CleanShutdown,
                       file_size_limit        = FileSizeLimit,
                       cref_to_guids          = dict:new()
                      },

    %% If we didn't recover the msg location index then we need to
    %% rebuild it now.
    {Offset, State1 = #msstate { current_file = CurFile }} =
        build_index(CleanShutdown, StartupFunState, State),

    %% read is only needed so that we can seek
    {ok, CurHdl} = open_file(Dir, filenum_to_name(CurFile),
                             [read | ?WRITE_MODE]),
    {ok, Offset} = file_handle_cache:position(CurHdl, Offset),
    ok = file_handle_cache:truncate(CurHdl),

    {ok, GCPid} = rabbit_msg_store_gc:start_link(
                    #gc_state { dir              = Dir,
                                index_module     = IndexModule,
                                index_state      = IndexState,
                                file_summary_ets = FileSummaryEts,
                                file_handles_ets = FileHandlesEts,
                                msg_store        = self()
                              }),

    {ok, maybe_compact(
           State1 #msstate { current_file_handle = CurHdl, gc_pid = GCPid }),
     hibernate,
     {backoff, ?HIBERNATE_AFTER_MIN, ?HIBERNATE_AFTER_MIN, ?DESIRED_HIBERNATE}}.

prioritise_call(Msg, _From, _State) ->
    case Msg of
        successfully_recovered_state                  -> 7;
        {new_client_state, _Ref, _MODC, _CloseFDsFun} -> 7;
        {read, _Guid}                                 -> 2;
        _                                             -> 0
    end.

prioritise_cast(Msg, _State) ->
    case Msg of
        sync                                               -> 8;
        {combine_files, _Source, _Destination, _Reclaimed} -> 8;
        {delete_file, _File, _Reclaimed}                   -> 8;
        {set_maximum_since_use, _Age}                      -> 8;
        {client_dying, _Pid}                               -> 7;
        _                                                  -> 0
    end.

handle_call(successfully_recovered_state, _From, State) ->
    reply(State #msstate.successfully_recovered, State);

handle_call({new_client_state, CRef, MsgOnDiskFun, CloseFDsFun}, _From,
            State = #msstate { dir                    = Dir,
                               index_state            = IndexState,
                               index_module           = IndexModule,
                               file_handles_ets       = FileHandlesEts,
                               file_summary_ets       = FileSummaryEts,
                               dedup_cache_ets        = DedupCacheEts,
                               cur_file_cache_ets     = CurFileCacheEts,
                               clients                = Clients,
                               gc_pid                 = GCPid }) ->
    Clients1 = dict:store(CRef, {MsgOnDiskFun, CloseFDsFun}, Clients),
    reply({IndexState, IndexModule, Dir, GCPid,
           FileHandlesEts, FileSummaryEts, DedupCacheEts, CurFileCacheEts},
          State #msstate { clients = Clients1 });

handle_call({client_terminate, CRef}, _From, State) ->
    reply(ok, clear_client(CRef, State));

handle_call({read, Guid}, From, State) ->
    State1 = read_message(Guid, From, State),
    noreply(State1);

handle_call({contains, Guid}, From, State) ->
    State1 = contains_message(Guid, From, State),
    noreply(State1).

handle_cast({client_dying, CRef},
            State = #msstate { dying_clients = DyingClients }) ->
    DyingClients1 = sets:add_element(CRef, DyingClients),
    noreply(write_message(CRef, <<>>,
                          State #msstate { dying_clients = DyingClients1 }));

handle_cast({client_delete, CRef}, State = #msstate { clients = Clients }) ->
    State1 = State #msstate { clients = dict:erase(CRef, Clients) },
    noreply(remove_message(CRef, CRef, clear_client(CRef, State1)));

handle_cast({write, CRef, Guid},
            State = #msstate { cur_file_cache_ets = CurFileCacheEts }) ->
    true = 0 =< ets:update_counter(CurFileCacheEts, Guid, {3, -1}),
    [{Guid, Msg, _CacheRefCount}] = ets:lookup(CurFileCacheEts, Guid),
    noreply(
      case write_action(should_mask_action(CRef, Guid, State), Guid, State) of
          {write, State1} ->
              write_message(CRef, Guid, Msg, State1);
          {ignore, CurFile, State1 = #msstate { current_file = CurFile }} ->
              State1;
          {ignore, _File, State1} ->
              true = ets:delete_object(CurFileCacheEts, {Guid, Msg, 0}),
              State1;
          {confirm, CurFile, State1 = #msstate { current_file = CurFile }}->
              record_pending_confirm(CRef, Guid, State1);
          {confirm, _File, State1} ->
              true = ets:delete_object(CurFileCacheEts, {Guid, Msg, 0}),
              update_pending_confirms(
                fun (MsgOnDiskFun, CTG) ->
                        MsgOnDiskFun(gb_sets:singleton(Guid), written),
                        CTG
                end, CRef, State1)
      end);

handle_cast({remove, CRef, Guids}, State) ->
    State1 = lists:foldl(
               fun (Guid, State2) -> remove_message(Guid, CRef, State2) end,
               State, Guids),
    noreply(maybe_compact(
              client_confirm(CRef, gb_sets:from_list(Guids), removed, State1)));

handle_cast({release, Guids}, State =
                #msstate { dedup_cache_ets = DedupCacheEts }) ->
    lists:foreach(
      fun (Guid) -> decrement_cache(DedupCacheEts, Guid) end, Guids),
    noreply(State);

handle_cast({sync, Guids, K},
            State = #msstate { current_file        = CurFile,
                               current_file_handle = CurHdl,
                               on_sync             = Syncs }) ->
    {ok, SyncOffset} = file_handle_cache:last_sync_offset(CurHdl),
    case lists:any(fun (Guid) ->
                           #msg_location { file = File, offset = Offset } =
                               index_lookup(Guid, State),
                           File =:= CurFile andalso Offset >= SyncOffset
                   end, Guids) of
        false -> K(),
                 noreply(State);
        true  -> noreply(State #msstate { on_sync = [K | Syncs] })
    end;

handle_cast(sync, State) ->
    noreply(internal_sync(State));

handle_cast({combine_files, Source, Destination, Reclaimed},
            State = #msstate { sum_file_size    = SumFileSize,
                               file_handles_ets = FileHandlesEts,
                               file_summary_ets = FileSummaryEts,
                               clients          = Clients }) ->
    ok = cleanup_after_file_deletion(Source, State),
    %% see comment in cleanup_after_file_deletion, and client_read3
    true = mark_handle_to_close(Clients, FileHandlesEts, Destination, false),
    true = ets:update_element(FileSummaryEts, Destination,
                              {#file_summary.locked, false}),
    State1 = State #msstate { sum_file_size = SumFileSize - Reclaimed },
    noreply(maybe_compact(run_pending([Source, Destination], State1)));

handle_cast({delete_file, File, Reclaimed},
            State = #msstate { sum_file_size = SumFileSize }) ->
    ok = cleanup_after_file_deletion(File, State),
    State1 = State #msstate { sum_file_size = SumFileSize - Reclaimed },
    noreply(maybe_compact(run_pending([File], State1)));

handle_cast({set_maximum_since_use, Age}, State) ->
    ok = file_handle_cache:set_maximum_since_use(Age),
    noreply(State).

handle_info(timeout, State) ->
    noreply(internal_sync(State));

handle_info({'EXIT', _Pid, Reason}, State) ->
    {stop, Reason, State}.

terminate(_Reason, State = #msstate { index_state         = IndexState,
                                      index_module        = IndexModule,
                                      current_file_handle = CurHdl,
                                      gc_pid              = GCPid,
                                      file_handles_ets    = FileHandlesEts,
                                      file_summary_ets    = FileSummaryEts,
                                      dedup_cache_ets     = DedupCacheEts,
                                      cur_file_cache_ets  = CurFileCacheEts,
                                      clients             = Clients,
                                      dir                 = Dir }) ->
    %% stop the gc first, otherwise it could be working and we pull
    %% out the ets tables from under it.
    ok = rabbit_msg_store_gc:stop(GCPid),
    State1 = case CurHdl of
                 undefined -> State;
                 _         -> State2 = internal_sync(State),
                              file_handle_cache:close(CurHdl),
                              State2
             end,
    State3 = close_all_handles(State1),
    store_file_summary(FileSummaryEts, Dir),
    [ets:delete(T) ||
        T <- [FileSummaryEts, DedupCacheEts, FileHandlesEts, CurFileCacheEts]],
    IndexModule:terminate(IndexState),
    store_recovery_terms([{client_refs, dict:fetch_keys(Clients)},
                          {index_module, IndexModule}], Dir),
    State3 #msstate { index_state         = undefined,
                      current_file_handle = undefined }.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%----------------------------------------------------------------------------
%% general helper functions
%%----------------------------------------------------------------------------

noreply(State) ->
    {State1, Timeout} = next_state(State),
    {noreply, State1, Timeout}.

reply(Reply, State) ->
    {State1, Timeout} = next_state(State),
    {reply, Reply, State1, Timeout}.

next_state(State = #msstate { sync_timer_ref = undefined,
                              on_sync        = Syncs,
                              cref_to_guids  = CTG }) ->
    case {Syncs, dict:size(CTG)} of
        {[], 0} -> {State, hibernate};
        _       -> {start_sync_timer(State), 0}
    end;
next_state(State = #msstate { on_sync       = Syncs,
                              cref_to_guids = CTG }) ->
    case {Syncs, dict:size(CTG)} of
        {[], 0} -> {stop_sync_timer(State), hibernate};
        _       -> {State, 0}
    end.

start_sync_timer(State = #msstate { sync_timer_ref = undefined }) ->
    {ok, TRef} = timer:apply_after(?SYNC_INTERVAL, ?MODULE, sync, [self()]),
    State #msstate { sync_timer_ref = TRef }.

stop_sync_timer(State = #msstate { sync_timer_ref = undefined }) ->
    State;
stop_sync_timer(State = #msstate { sync_timer_ref = TRef }) ->
    {ok, cancel} = timer:cancel(TRef),
    State #msstate { sync_timer_ref = undefined }.

internal_sync(State = #msstate { current_file_handle = CurHdl,
                                 on_sync             = Syncs,
                                 cref_to_guids       = CTG }) ->
    State1 = stop_sync_timer(State),
    CGs = dict:fold(fun (CRef, Guids, NS) ->
                            case gb_sets:is_empty(Guids) of
                                true  -> NS;
                                false -> [{CRef, Guids} | NS]
                            end
                    end, [], CTG),
    case {Syncs, CGs} of
        {[], []} -> ok;
        _        -> file_handle_cache:sync(CurHdl)
    end,
    [K() || K <- lists:reverse(Syncs)],
    [client_confirm(CRef, Guids, written, State1) || {CRef, Guids} <- CGs],
    State1 #msstate { cref_to_guids = dict:new(), on_sync = [] }.

write_action({true, not_found}, _Guid, State) ->
    {ignore, undefined, State};
write_action({true, #msg_location { file = File }}, _Guid, State) ->
    {ignore, File, State};
write_action({false, not_found}, _Guid, State) ->
    {write, State};
write_action({Mask, #msg_location { ref_count = 0, file = File,
                                    total_size = TotalSize }},
             Guid, State = #msstate { file_summary_ets = FileSummaryEts }) ->
    case {Mask, ets:lookup(FileSummaryEts, File)} of
        {false, [#file_summary { locked = true }]} ->
            ok = index_delete(Guid, State),
            {write, State};
        {false_if_increment, [#file_summary { locked = true }]} ->
            %% The msg for Guid is older than the client death
            %% message, but as it is being GC'd currently we'll have
            %% to write a new copy, which will then be younger, so
            %% ignore this write.
            {ignore, File, State};
        {_Mask, [#file_summary {}]} ->
            ok = index_update_ref_count(Guid, 1, State),
            State1 = adjust_valid_total_size(File, TotalSize, State),
            {confirm, File, State1}
    end;
write_action({_Mask, #msg_location { ref_count = RefCount, file = File }},
             Guid, State) ->
    ok = index_update_ref_count(Guid, RefCount + 1, State),
    %% We already know about it, just update counter. Only update
    %% field otherwise bad interaction with concurrent GC
    {confirm, File, State}.

write_message(CRef, Guid, Msg, State) ->
    write_message(Guid, Msg, record_pending_confirm(CRef, Guid, State)).

write_message(Guid, Msg,
              State = #msstate { current_file_handle = CurHdl,
                                 current_file        = CurFile,
                                 sum_valid_data      = SumValid,
                                 sum_file_size       = SumFileSize,
                                 file_summary_ets    = FileSummaryEts }) ->
    {ok, CurOffset} = file_handle_cache:current_virtual_offset(CurHdl),
    {ok, TotalSize} = rabbit_msg_file:append(CurHdl, Guid, Msg),
    ok = index_insert(
           #msg_location { guid = Guid, ref_count = 1, file = CurFile,
                           offset = CurOffset, total_size = TotalSize }, State),
    [#file_summary { right = undefined, locked = false }] =
        ets:lookup(FileSummaryEts, CurFile),
    [_,_] = ets:update_counter(FileSummaryEts, CurFile,
                               [{#file_summary.valid_total_size, TotalSize},
                                {#file_summary.file_size,        TotalSize}]),
    maybe_roll_to_new_file(CurOffset + TotalSize,
                           State #msstate {
                             sum_valid_data = SumValid    + TotalSize,
                             sum_file_size  = SumFileSize + TotalSize }).

read_message(Guid, From,
             State = #msstate { dedup_cache_ets = DedupCacheEts }) ->
    case index_lookup_positive_ref_count(Guid, State) of
        not_found ->
            gen_server2:reply(From, not_found),
            State;
        MsgLocation ->
            case fetch_and_increment_cache(DedupCacheEts, Guid) of
                not_found -> read_message1(From, MsgLocation, State);
                Msg       -> gen_server2:reply(From, {ok, Msg}),
                             State
            end
    end.

read_message1(From, #msg_location { guid = Guid, ref_count = RefCount,
                                    file = File, offset = Offset } = MsgLoc,
              State = #msstate { current_file        = CurFile,
                                 current_file_handle = CurHdl,
                                 file_summary_ets    = FileSummaryEts,
                                 dedup_cache_ets     = DedupCacheEts,
                                 cur_file_cache_ets  = CurFileCacheEts }) ->
    case File =:= CurFile of
        true  -> {Msg, State1} =
                     %% can return [] if msg in file existed on startup
                     case ets:lookup(CurFileCacheEts, Guid) of
                         [] ->
                             {ok, RawOffSet} =
                                 file_handle_cache:current_raw_offset(CurHdl),
                             ok = case Offset >= RawOffSet of
                                      true  -> file_handle_cache:flush(CurHdl);
                                      false -> ok
                                  end,
                             read_from_disk(MsgLoc, State, DedupCacheEts);
                         [{Guid, Msg1, _CacheRefCount}] ->
                             ok = maybe_insert_into_cache(
                                    DedupCacheEts, RefCount, Guid, Msg1),
                             {Msg1, State}
                     end,
                 gen_server2:reply(From, {ok, Msg}),
                 State1;
        false -> [#file_summary { locked = Locked }] =
                     ets:lookup(FileSummaryEts, File),
                 case Locked of
                     true  -> add_to_pending_gc_completion({read, Guid, From},
                                                           File, State);
                     false -> {Msg, State1} =
                                  read_from_disk(MsgLoc, State, DedupCacheEts),
                              gen_server2:reply(From, {ok, Msg}),
                              State1
                 end
    end.

read_from_disk(#msg_location { guid = Guid, ref_count = RefCount,
                               file = File, offset = Offset,
                               total_size = TotalSize },
               State, DedupCacheEts) ->
    {Hdl, State1} = get_read_handle(File, State),
    {ok, Offset} = file_handle_cache:position(Hdl, Offset),
    {ok, {Guid, Msg}} =
        case rabbit_msg_file:read(Hdl, TotalSize) of
            {ok, {Guid, _}} = Obj ->
                Obj;
            Rest ->
                {error, {misread, [{old_state, State},
                                   {file_num,  File},
                                   {offset,    Offset},
                                   {guid,      Guid},
                                   {read,      Rest},
                                   {proc_dict, get()}
                                  ]}}
        end,
    ok = maybe_insert_into_cache(DedupCacheEts, RefCount, Guid, Msg),
    {Msg, State1}.

contains_message(Guid, From,
                 State = #msstate { pending_gc_completion = Pending }) ->
    case index_lookup_positive_ref_count(Guid, State) of
        not_found ->
            gen_server2:reply(From, false),
            State;
        #msg_location { file = File } ->
            case orddict:is_key(File, Pending) of
                true  -> add_to_pending_gc_completion(
                           {contains, Guid, From}, File, State);
                false -> gen_server2:reply(From, true),
                         State
            end
    end.

remove_message(Guid, CRef,
               State = #msstate { file_summary_ets = FileSummaryEts,
                                  dedup_cache_ets  = DedupCacheEts }) ->
    case should_mask_action(CRef, Guid, State) of
        {true, _Location} ->
            State;
        {false_if_increment, #msg_location { ref_count = 0 }} ->
            %% CRef has tried to both write and remove this msg
            %% whilst it's being GC'd. ASSERTION:
            %% [#file_summary { locked = true }] =
            %%    ets:lookup(FileSummaryEts, File),
            State;
        {_Mask, #msg_location { ref_count = RefCount, file = File,
                                total_size = TotalSize }} when RefCount > 0 ->
            %% only update field, otherwise bad interaction with
            %% concurrent GC
            Dec =
                fun () -> index_update_ref_count(Guid, RefCount - 1, State) end,
            case RefCount of
                %% don't remove from CUR_FILE_CACHE_ETS_NAME here
                %% because there may be further writes in the mailbox
                %% for the same msg.
                1 -> ok = remove_cache_entry(DedupCacheEts, Guid),
                     case ets:lookup(FileSummaryEts, File) of
                         [#file_summary { locked = true }] ->
                             add_to_pending_gc_completion(
                               {remove, Guid, CRef}, File, State);
                         [#file_summary {}] ->
                             ok = Dec(),
                             delete_file_if_empty(
                               File, adjust_valid_total_size(File, -TotalSize,
                                                             State))
                     end;
                _ -> ok = decrement_cache(DedupCacheEts, Guid),
                     ok = Dec(),
                     State
            end
    end.

add_to_pending_gc_completion(
  Op, File, State = #msstate { pending_gc_completion = Pending }) ->
    State #msstate { pending_gc_completion =
                         rabbit_misc:orddict_cons(File, Op, Pending) }.

run_pending(Files, State) ->
    lists:foldl(
      fun (File, State1 = #msstate { pending_gc_completion = Pending }) ->
              Pending1 = orddict:erase(File, Pending),
              lists:foldl(
                fun run_pending_action/2,
                State1 #msstate { pending_gc_completion = Pending1 },
                lists:reverse(orddict:fetch(File, Pending)))
      end, State, Files).

run_pending_action({read, Guid, From}, State) ->
    read_message(Guid, From, State);
run_pending_action({contains, Guid, From}, State) ->
    contains_message(Guid, From, State);
run_pending_action({remove, Guid, CRef}, State) ->
    remove_message(Guid, CRef, State).

safe_ets_update_counter(Tab, Key, UpdateOp, SuccessFun, FailThunk) ->
    try
        SuccessFun(ets:update_counter(Tab, Key, UpdateOp))
    catch error:badarg -> FailThunk()
    end.

safe_ets_update_counter_ok(Tab, Key, UpdateOp, FailThunk) ->
    safe_ets_update_counter(Tab, Key, UpdateOp, fun (_) -> ok end, FailThunk).

adjust_valid_total_size(File, Delta, State = #msstate {
                                       sum_valid_data   = SumValid,
                                       file_summary_ets = FileSummaryEts }) ->
    [_] = ets:update_counter(FileSummaryEts, File,
                             [{#file_summary.valid_total_size, Delta}]),
    State #msstate { sum_valid_data = SumValid + Delta }.

orddict_store(Key, Val, Dict) ->
    false = orddict:is_key(Key, Dict),
    orddict:store(Key, Val, Dict).

update_pending_confirms(Fun, CRef, State = #msstate { clients       = Clients,
                                                      cref_to_guids = CTG }) ->
    case dict:fetch(CRef, Clients) of
        {undefined,    _CloseFDsFun} -> State;
        {MsgOnDiskFun, _CloseFDsFun} -> CTG1 = Fun(MsgOnDiskFun, CTG),
                                        State #msstate { cref_to_guids = CTG1 }
    end.

record_pending_confirm(CRef, Guid, State) ->
    update_pending_confirms(
      fun (_MsgOnDiskFun, CTG) ->
              dict:update(CRef, fun (Guids) -> gb_sets:add(Guid, Guids) end,
                          gb_sets:singleton(Guid), CTG)
      end, CRef, State).

client_confirm(CRef, Guids, ActionTaken, State) ->
    update_pending_confirms(
      fun (MsgOnDiskFun, CTG) ->
              MsgOnDiskFun(Guids, ActionTaken),
              case dict:find(CRef, CTG) of
                  {ok, Gs} -> Guids1 = gb_sets:difference(Gs, Guids),
                              case gb_sets:is_empty(Guids1) of
                                  true  -> dict:erase(CRef, CTG);
                                  false -> dict:store(CRef, Guids1, CTG)
                              end;
                  error    -> CTG
              end
      end, CRef, State).

%% Detect whether the Guid is older or younger than the client's death
%% msg (if there is one). If the msg is older than the client death
%% msg, and it has a 0 ref_count we must only alter the ref_count, not
%% rewrite the msg - rewriting it would make it younger than the death
%% msg and thus should be ignored. Note that this (correctly) returns
%% false when testing to remove the death msg itself.
should_mask_action(CRef, Guid,
                   State = #msstate { dying_clients = DyingClients }) ->
    case {sets:is_element(CRef, DyingClients), index_lookup(Guid, State)} of
        {false, Location} ->
            {false, Location};
        {true, not_found} ->
            {true, not_found};
        {true, #msg_location { file = File, offset = Offset,
                               ref_count = RefCount } = Location} ->
            #msg_location { file = DeathFile, offset = DeathOffset } =
                index_lookup(CRef, State),
            {case {{DeathFile, DeathOffset} < {File, Offset}, RefCount} of
                 {true,  _} -> true;
                 {false, 0} -> false_if_increment;
                 {false, _} -> false
             end, Location}
    end.

%%----------------------------------------------------------------------------
%% file helper functions
%%----------------------------------------------------------------------------

open_file(Dir, FileName, Mode) ->
    file_handle_cache:open(form_filename(Dir, FileName), ?BINARY_MODE ++ Mode,
                           [{write_buffer, ?HANDLE_CACHE_BUFFER_SIZE}]).

close_handle(Key, CState = #client_msstate { file_handle_cache = FHC }) ->
    CState #client_msstate { file_handle_cache = close_handle(Key, FHC) };

close_handle(Key, State = #msstate { file_handle_cache = FHC }) ->
    State #msstate { file_handle_cache = close_handle(Key, FHC) };

close_handle(Key, FHC) ->
    case dict:find(Key, FHC) of
        {ok, Hdl} -> ok = file_handle_cache:close(Hdl),
                     dict:erase(Key, FHC);
        error     -> FHC
    end.

mark_handle_open(FileHandlesEts, File, Ref) ->
    %% This is fine to fail (already exists). Note it could fail with
    %% the value being close, and not have it updated to open.
    ets:insert_new(FileHandlesEts, {{Ref, File}, open}),
    true.

%% See comment in client_read3 - only call this when the file is locked
mark_handle_to_close(ClientRefs, FileHandlesEts, File, Invoke) ->
    [ begin
          case (ets:update_element(FileHandlesEts, Key, {2, close})
                andalso Invoke) of
              true  -> case dict:fetch(Ref, ClientRefs) of
                           {_MsgOnDiskFun, undefined}   -> ok;
                           {_MsgOnDiskFun, CloseFDsFun} -> ok = CloseFDsFun()
                       end;
              false -> ok
          end
      end || {{Ref, _File} = Key, open} <-
                 ets:match_object(FileHandlesEts, {{'_', File}, open}) ],
    true.

safe_file_delete_fun(File, Dir, FileHandlesEts) ->
    fun () -> safe_file_delete(File, Dir, FileHandlesEts) end.

safe_file_delete(File, Dir, FileHandlesEts) ->
    %% do not match on any value - it's the absence of the row that
    %% indicates the client has really closed the file.
    case ets:match_object(FileHandlesEts, {{'_', File}, '_'}, 1) of
        {[_|_], _Cont} -> false;
        _              -> ok = file:delete(
                                 form_filename(Dir, filenum_to_name(File))),
                          true
    end.

close_all_indicated(#client_msstate { file_handles_ets = FileHandlesEts,
                                      client_ref       = Ref } =
                    CState) ->
    Objs = ets:match_object(FileHandlesEts, {{Ref, '_'}, close}),
    {ok, lists:foldl(fun ({Key = {_Ref, File}, close}, CStateM) ->
                             true = ets:delete(FileHandlesEts, Key),
                             close_handle(File, CStateM)
                     end, CState, Objs)}.

close_all_handles(CState = #client_msstate { file_handles_ets  = FileHandlesEts,
                                             file_handle_cache = FHC,
                                             client_ref        = Ref }) ->
    ok = dict:fold(fun (File, Hdl, ok) ->
                           true = ets:delete(FileHandlesEts, {Ref, File}),
                           file_handle_cache:close(Hdl)
                   end, ok, FHC),
    CState #client_msstate { file_handle_cache = dict:new() };

close_all_handles(State = #msstate { file_handle_cache = FHC }) ->
    ok = dict:fold(fun (_Key, Hdl, ok) -> file_handle_cache:close(Hdl) end,
                   ok, FHC),
    State #msstate { file_handle_cache = dict:new() }.

get_read_handle(FileNum, CState = #client_msstate { file_handle_cache = FHC,
                                                    dir = Dir }) ->
    {Hdl, FHC2} = get_read_handle(FileNum, FHC, Dir),
    {Hdl, CState #client_msstate { file_handle_cache = FHC2 }};

get_read_handle(FileNum, State = #msstate { file_handle_cache = FHC,
                                            dir = Dir }) ->
    {Hdl, FHC2} = get_read_handle(FileNum, FHC, Dir),
    {Hdl, State #msstate { file_handle_cache = FHC2 }}.

get_read_handle(FileNum, FHC, Dir) ->
    case dict:find(FileNum, FHC) of
        {ok, Hdl} -> {Hdl, FHC};
        error     -> {ok, Hdl} = open_file(Dir, filenum_to_name(FileNum),
                                           ?READ_MODE),
                     {Hdl, dict:store(FileNum, Hdl, FHC)}
    end.

preallocate(Hdl, FileSizeLimit, FinalPos) ->
    {ok, FileSizeLimit} = file_handle_cache:position(Hdl, FileSizeLimit),
    ok = file_handle_cache:truncate(Hdl),
    {ok, FinalPos} = file_handle_cache:position(Hdl, FinalPos),
    ok.

truncate_and_extend_file(Hdl, Lowpoint, Highpoint) ->
    {ok, Lowpoint} = file_handle_cache:position(Hdl, Lowpoint),
    ok = file_handle_cache:truncate(Hdl),
    ok = preallocate(Hdl, Highpoint, Lowpoint).

form_filename(Dir, Name) -> filename:join(Dir, Name).

filenum_to_name(File) -> integer_to_list(File) ++ ?FILE_EXTENSION.

filename_to_num(FileName) -> list_to_integer(filename:rootname(FileName)).

list_sorted_file_names(Dir, Ext) ->
    lists:sort(fun (A, B) -> filename_to_num(A) < filename_to_num(B) end,
               filelib:wildcard("*" ++ Ext, Dir)).

%%----------------------------------------------------------------------------
%% message cache helper functions
%%----------------------------------------------------------------------------

maybe_insert_into_cache(DedupCacheEts, RefCount, Guid, Msg)
  when RefCount > 1 ->
    update_msg_cache(DedupCacheEts, Guid, Msg);
maybe_insert_into_cache(_DedupCacheEts, _RefCount, _Guid, _Msg) ->
    ok.

update_msg_cache(CacheEts, Guid, Msg) ->
    case ets:insert_new(CacheEts, {Guid, Msg, 1}) of
        true  -> ok;
        false -> safe_ets_update_counter_ok(
                   CacheEts, Guid, {3, +1},
                   fun () -> update_msg_cache(CacheEts, Guid, Msg) end)
    end.

remove_cache_entry(DedupCacheEts, Guid) ->
    true = ets:delete(DedupCacheEts, Guid),
    ok.

fetch_and_increment_cache(DedupCacheEts, Guid) ->
    case ets:lookup(DedupCacheEts, Guid) of
        [] ->
            not_found;
        [{_Guid, Msg, _RefCount}] ->
            safe_ets_update_counter_ok(
              DedupCacheEts, Guid, {3, +1},
              %% someone has deleted us in the meantime, insert us
              fun () -> ok = update_msg_cache(DedupCacheEts, Guid, Msg) end),
            Msg
    end.

decrement_cache(DedupCacheEts, Guid) ->
    true = safe_ets_update_counter(
             DedupCacheEts, Guid, {3, -1},
             fun (N) when N =< 0 -> true = ets:delete(DedupCacheEts, Guid);
                 (_N)            -> true
             end,
             %% Guid is not in there because although it's been
             %% delivered, it's never actually been read (think:
             %% persistent message held in RAM)
             fun () -> true end),
    ok.

%%----------------------------------------------------------------------------
%% index
%%----------------------------------------------------------------------------

index_lookup_positive_ref_count(Key, State) ->
    case index_lookup(Key, State) of
        not_found                       -> not_found;
        #msg_location { ref_count = 0 } -> not_found;
        #msg_location {} = MsgLocation  -> MsgLocation
    end.

index_update_ref_count(Key, RefCount, State) ->
    index_update_fields(Key, {#msg_location.ref_count, RefCount}, State).

index_lookup(Key, #client_msstate { index_module = Index,
                                    index_state  = State }) ->
    Index:lookup(Key, State);

index_lookup(Key, #msstate { index_module = Index, index_state = State }) ->
    Index:lookup(Key, State).

index_insert(Obj, #msstate { index_module = Index, index_state = State }) ->
    Index:insert(Obj, State).

index_update(Obj, #msstate { index_module = Index, index_state = State }) ->
    Index:update(Obj, State).

index_update_fields(Key, Updates, #msstate { index_module = Index,
                                             index_state  = State }) ->
    Index:update_fields(Key, Updates, State).

index_delete(Key, #msstate { index_module = Index, index_state = State }) ->
    Index:delete(Key, State).

index_delete_by_file(File, #msstate { index_module = Index,
                                      index_state  = State }) ->
    Index:delete_by_file(File, State).

%%----------------------------------------------------------------------------
%% shutdown and recovery
%%----------------------------------------------------------------------------

recover_index_and_client_refs(IndexModule, _Recover, undefined, Dir, _Server) ->
    {false, IndexModule:new(Dir), []};
recover_index_and_client_refs(IndexModule, false, _ClientRefs, Dir, Server) ->
    rabbit_log:warning("~w: rebuilding indices from scratch~n", [Server]),
    {false, IndexModule:new(Dir), []};
recover_index_and_client_refs(IndexModule, true, ClientRefs, Dir, Server) ->
    Fresh = fun (ErrorMsg, ErrorArgs) ->
                    rabbit_log:warning("~w: " ++ ErrorMsg ++ "~n"
                                       "rebuilding indices from scratch~n",
                                       [Server | ErrorArgs]),
                    {false, IndexModule:new(Dir), []}
            end,
    case read_recovery_terms(Dir) of
        {false, Error} ->
            Fresh("failed to read recovery terms: ~p", [Error]);
        {true, Terms} ->
            RecClientRefs  = proplists:get_value(client_refs, Terms, []),
            RecIndexModule = proplists:get_value(index_module, Terms),
            case (lists:sort(ClientRefs) =:= lists:sort(RecClientRefs)
                  andalso IndexModule =:= RecIndexModule) of
                true  -> case IndexModule:recover(Dir) of
                             {ok, IndexState1} ->
                                 {true, IndexState1, ClientRefs};
                             {error, Error} ->
                                 Fresh("failed to recover index: ~p", [Error])
                         end;
                false -> Fresh("recovery terms differ from present", [])
            end
    end.

store_recovery_terms(Terms, Dir) ->
    rabbit_misc:write_term_file(filename:join(Dir, ?CLEAN_FILENAME), Terms).

read_recovery_terms(Dir) ->
    Path = filename:join(Dir, ?CLEAN_FILENAME),
    case rabbit_misc:read_term_file(Path) of
        {ok, Terms}    -> case file:delete(Path) of
                              ok             -> {true,  Terms};
                              {error, Error} -> {false, Error}
                          end;
        {error, Error} -> {false, Error}
    end.

store_file_summary(Tid, Dir) ->
    ok = ets:tab2file(Tid, filename:join(Dir, ?FILE_SUMMARY_FILENAME),
                      [{extended_info, [object_count]}]).

recover_file_summary(false, _Dir) ->
    %% TODO: the only reason for this to be an *ordered*_set is so
    %% that a) maybe_compact can start a traversal from the eldest
    %% file, and b) build_index in fast recovery mode can easily
    %% identify the current file. It's awkward to have both that
    %% odering and the left/right pointers in the entries - replacing
    %% the former with some additional bit of state would be easy, but
    %% ditching the latter would be neater.
    {false, ets:new(rabbit_msg_store_file_summary,
                    [ordered_set, public, {keypos, #file_summary.file}])};
recover_file_summary(true, Dir) ->
    Path = filename:join(Dir, ?FILE_SUMMARY_FILENAME),
    case ets:file2tab(Path) of
        {ok, Tid}       -> file:delete(Path),
                          {true, Tid};
        {error, _Error} -> recover_file_summary(false, Dir)
    end.

count_msg_refs(Gen, Seed, State) ->
    case Gen(Seed) of
        finished ->
            ok;
        {_Guid, 0, Next} ->
            count_msg_refs(Gen, Next, State);
        {Guid, Delta, Next} ->
            ok = case index_lookup(Guid, State) of
                     not_found ->
                         index_insert(#msg_location { guid = Guid,
                                                      file = undefined,
                                                      ref_count = Delta },
                                      State);
                     #msg_location { ref_count = RefCount } = StoreEntry ->
                         NewRefCount = RefCount + Delta,
                         case NewRefCount of
                             0 -> index_delete(Guid, State);
                             _ -> index_update(StoreEntry #msg_location {
                                                 ref_count = NewRefCount },
                                               State)
                         end
                 end,
            count_msg_refs(Gen, Next, State)
    end.

recover_crashed_compactions(Dir) ->
    FileNames =    list_sorted_file_names(Dir, ?FILE_EXTENSION),
    TmpFileNames = list_sorted_file_names(Dir, ?FILE_EXTENSION_TMP),
    lists:foreach(
      fun (TmpFileName) ->
              NonTmpRelatedFileName =
                  filename:rootname(TmpFileName) ++ ?FILE_EXTENSION,
              true = lists:member(NonTmpRelatedFileName, FileNames),
              ok = recover_crashed_compaction(
                     Dir, TmpFileName, NonTmpRelatedFileName)
      end, TmpFileNames),
    TmpFileNames == [].

recover_crashed_compaction(Dir, TmpFileName, NonTmpRelatedFileName) ->
    %% Because a msg can legitimately appear multiple times in the
    %% same file, identifying the contents of the tmp file and where
    %% they came from is non-trivial. If we are recovering a crashed
    %% compaction then we will be rebuilding the index, which can cope
    %% with duplicates appearing. Thus the simplest and safest thing
    %% to do is to append the contents of the tmp file to its main
    %% file.
    {ok, TmpHdl}  = open_file(Dir, TmpFileName, ?READ_MODE),
    {ok, MainHdl} = open_file(Dir, NonTmpRelatedFileName,
                              ?READ_MODE ++ ?WRITE_MODE),
    {ok, _End} = file_handle_cache:position(MainHdl, eof),
    Size = filelib:file_size(form_filename(Dir, TmpFileName)),
    {ok, Size} = file_handle_cache:copy(TmpHdl, MainHdl, Size),
    ok = file_handle_cache:close(MainHdl),
    ok = file_handle_cache:delete(TmpHdl),
    ok.

scan_file_for_valid_messages(Dir, FileName) ->
    case open_file(Dir, FileName, ?READ_MODE) of
        {ok, Hdl}       -> Valid = rabbit_msg_file:scan(
                                     Hdl, filelib:file_size(
                                            form_filename(Dir, FileName))),
                           %% if something really bad has happened,
                           %% the close could fail, but ignore
                           file_handle_cache:close(Hdl),
                           Valid;
        {error, enoent} -> {ok, [], 0};
        {error, Reason} -> {error, {unable_to_scan_file, FileName, Reason}}
    end.

%% Takes the list in *ascending* order (i.e. eldest message
%% first). This is the opposite of what scan_file_for_valid_messages
%% produces. The list of msgs that is produced is youngest first.
drop_contiguous_block_prefix(L) -> drop_contiguous_block_prefix(L, 0).

drop_contiguous_block_prefix([], ExpectedOffset) ->
    {ExpectedOffset, []};
drop_contiguous_block_prefix([#msg_location { offset = ExpectedOffset,
                                              total_size = TotalSize } | Tail],
                             ExpectedOffset) ->
    ExpectedOffset1 = ExpectedOffset + TotalSize,
    drop_contiguous_block_prefix(Tail, ExpectedOffset1);
drop_contiguous_block_prefix(MsgsAfterGap, ExpectedOffset) ->
    {ExpectedOffset, MsgsAfterGap}.

build_index(true, _StartupFunState,
            State = #msstate { file_summary_ets = FileSummaryEts }) ->
    ets:foldl(
      fun (#file_summary { valid_total_size = ValidTotalSize,
                           file_size        = FileSize,
                           file             = File },
           {_Offset, State1 = #msstate { sum_valid_data = SumValid,
                                         sum_file_size  = SumFileSize }}) ->
              {FileSize, State1 #msstate {
                           sum_valid_data = SumValid + ValidTotalSize,
                           sum_file_size  = SumFileSize + FileSize,
                           current_file   = File }}
      end, {0, State}, FileSummaryEts);
build_index(false, {MsgRefDeltaGen, MsgRefDeltaGenInit},
            State = #msstate { dir = Dir }) ->
    ok = count_msg_refs(MsgRefDeltaGen, MsgRefDeltaGenInit, State),
    {ok, Pid} = gatherer:start_link(),
    case [filename_to_num(FileName) ||
             FileName <- list_sorted_file_names(Dir, ?FILE_EXTENSION)] of
        []     -> build_index(Pid, undefined, [State #msstate.current_file],
                              State);
        Files  -> {Offset, State1} = build_index(Pid, undefined, Files, State),
                  {Offset, lists:foldl(fun delete_file_if_empty/2,
                                       State1, Files)}
    end.

build_index(Gatherer, Left, [],
            State = #msstate { file_summary_ets = FileSummaryEts,
                               sum_valid_data   = SumValid,
                               sum_file_size    = SumFileSize }) ->
    case gatherer:out(Gatherer) of
        empty ->
            ok = gatherer:stop(Gatherer),
            ok = rabbit_misc:unlink_and_capture_exit(Gatherer),
            ok = index_delete_by_file(undefined, State),
            Offset = case ets:lookup(FileSummaryEts, Left) of
                         []                                       -> 0;
                         [#file_summary { file_size = FileSize }] -> FileSize
                     end,
            {Offset, State #msstate { current_file = Left }};
        {value, #file_summary { valid_total_size = ValidTotalSize,
                                file_size = FileSize } = FileSummary} ->
            true = ets:insert_new(FileSummaryEts, FileSummary),
            build_index(Gatherer, Left, [],
                        State #msstate {
                          sum_valid_data = SumValid + ValidTotalSize,
                          sum_file_size  = SumFileSize + FileSize })
    end;
build_index(Gatherer, Left, [File|Files], State) ->
    ok = gatherer:fork(Gatherer),
    ok = worker_pool:submit_async(
           fun () -> build_index_worker(Gatherer, State,
                                        Left, File, Files)
           end),
    build_index(Gatherer, File, Files, State).

build_index_worker(Gatherer, State = #msstate { dir = Dir },
                   Left, File, Files) ->
    {ok, Messages, FileSize} =
        scan_file_for_valid_messages(Dir, filenum_to_name(File)),
    {ValidMessages, ValidTotalSize} =
        lists:foldl(
          fun (Obj = {Guid, TotalSize, Offset}, {VMAcc, VTSAcc}) ->
                  case index_lookup(Guid, State) of
                      #msg_location { file = undefined } = StoreEntry ->
                          ok = index_update(StoreEntry #msg_location {
                                              file = File, offset = Offset,
                                              total_size = TotalSize },
                                            State),
                          {[Obj | VMAcc], VTSAcc + TotalSize};
                      _ ->
                          {VMAcc, VTSAcc}
                  end
          end, {[], 0}, Messages),
    {Right, FileSize1} =
        case Files of
            %% if it's the last file, we'll truncate to remove any
            %% rubbish above the last valid message. This affects the
            %% file size.
            []    -> {undefined, case ValidMessages of
                                     [] -> 0;
                                     _  -> {_Guid, TotalSize, Offset} =
                                               lists:last(ValidMessages),
                                           Offset + TotalSize
                                 end};
            [F|_] -> {F, FileSize}
        end,
    ok = gatherer:in(Gatherer, #file_summary {
                       file             = File,
                       valid_total_size = ValidTotalSize,
                       left             = Left,
                       right            = Right,
                       file_size        = FileSize1,
                       locked           = false,
                       readers          = 0 }),
    ok = gatherer:finish(Gatherer).

%%----------------------------------------------------------------------------
%% garbage collection / compaction / aggregation -- internal
%%----------------------------------------------------------------------------

maybe_roll_to_new_file(
  Offset,
  State = #msstate { dir                 = Dir,
                     current_file_handle = CurHdl,
                     current_file        = CurFile,
                     file_summary_ets    = FileSummaryEts,
                     cur_file_cache_ets  = CurFileCacheEts,
                     file_size_limit     = FileSizeLimit })
  when Offset >= FileSizeLimit ->
    State1 = internal_sync(State),
    ok = file_handle_cache:close(CurHdl),
    NextFile = CurFile + 1,
    {ok, NextHdl} = open_file(Dir, filenum_to_name(NextFile), ?WRITE_MODE),
    true = ets:insert_new(FileSummaryEts, #file_summary {
                            file             = NextFile,
                            valid_total_size = 0,
                            left             = CurFile,
                            right            = undefined,
                            file_size        = 0,
                            locked           = false,
                            readers          = 0 }),
    true = ets:update_element(FileSummaryEts, CurFile,
                              {#file_summary.right, NextFile}),
    true = ets:match_delete(CurFileCacheEts, {'_', '_', 0}),
    maybe_compact(State1 #msstate { current_file_handle = NextHdl,
                                    current_file        = NextFile });
maybe_roll_to_new_file(_, State) ->
    State.

maybe_compact(State = #msstate { sum_valid_data        = SumValid,
                                 sum_file_size         = SumFileSize,
                                 gc_pid                = GCPid,
                                 pending_gc_completion = Pending,
                                 file_summary_ets      = FileSummaryEts,
                                 file_size_limit       = FileSizeLimit })
  when (SumFileSize > 2 * FileSizeLimit andalso
        (SumFileSize - SumValid) / SumFileSize > ?GARBAGE_FRACTION) ->
    %% TODO: the algorithm here is sub-optimal - it may result in a
    %% complete traversal of FileSummaryEts.
    case ets:first(FileSummaryEts) of
        '$end_of_table' ->
            State;
        First ->
            case find_files_to_combine(FileSummaryEts, FileSizeLimit,
                                       ets:lookup(FileSummaryEts, First)) of
                not_found ->
                    State;
                {Src, Dst} ->
                    Pending1 = orddict_store(Dst, [],
                                             orddict_store(Src, [], Pending)),
                    State1 = close_handle(Src, close_handle(Dst, State)),
                    true = ets:update_element(FileSummaryEts, Src,
                                              {#file_summary.locked, true}),
                    true = ets:update_element(FileSummaryEts, Dst,
                                              {#file_summary.locked, true}),
                    ok = rabbit_msg_store_gc:combine(GCPid, Src, Dst),
                    State1 #msstate { pending_gc_completion = Pending1 }
            end
    end;
maybe_compact(State) ->
    State.

find_files_to_combine(FileSummaryEts, FileSizeLimit,
                      [#file_summary { file             = Dst,
                                       valid_total_size = DstValid,
                                       right            = Src,
                                       locked           = DstLocked }]) ->
    case Src of
        undefined ->
            not_found;
        _   ->
            [#file_summary { file             = Src,
                             valid_total_size = SrcValid,
                             left             = Dst,
                             right            = SrcRight,
                             locked           = SrcLocked }] = Next =
                ets:lookup(FileSummaryEts, Src),
            case SrcRight of
                undefined -> not_found;
                _         -> case (DstValid + SrcValid =< FileSizeLimit) andalso
                                 (DstValid > 0) andalso (SrcValid > 0) andalso
                                 not (DstLocked orelse SrcLocked) of
                                 true  -> {Src, Dst};
                                 false -> find_files_to_combine(
                                            FileSummaryEts, FileSizeLimit, Next)
                             end
            end
    end.

delete_file_if_empty(File, State = #msstate { current_file = File }) ->
    State;
delete_file_if_empty(File, State = #msstate {
                             gc_pid                = GCPid,
                             file_summary_ets      = FileSummaryEts,
                             pending_gc_completion = Pending }) ->
    [#file_summary { valid_total_size = ValidData,
                     locked           = false }] =
        ets:lookup(FileSummaryEts, File),
    case ValidData of
        0 -> %% don't delete the file_summary_ets entry for File here
             %% because we could have readers which need to be able to
             %% decrement the readers count.
             true = ets:update_element(FileSummaryEts, File,
                                       {#file_summary.locked, true}),
             ok = rabbit_msg_store_gc:delete(GCPid, File),
             Pending1 = orddict_store(File, [], Pending),
             close_handle(File,
                          State #msstate { pending_gc_completion = Pending1 });
        _ -> State
    end.

cleanup_after_file_deletion(File,
                            #msstate { file_handles_ets = FileHandlesEts,
                                       file_summary_ets = FileSummaryEts,
                                       clients          = Clients }) ->
    %% Ensure that any clients that have open fhs to the file close
    %% them before using them again. This has to be done here (given
    %% it's done in the msg_store, and not the gc), and not when
    %% starting up the GC, because if done when starting up the GC,
    %% the client could find the close, and close and reopen the fh,
    %% whilst the GC is waiting for readers to disappear, before it's
    %% actually done the GC.
    true = mark_handle_to_close(Clients, FileHandlesEts, File, true),
    [#file_summary { left    = Left,
                     right   = Right,
                     locked  = true,
                     readers = 0 }] = ets:lookup(FileSummaryEts, File),
    %% We'll never delete the current file, so right is never undefined
    true = Right =/= undefined, %% ASSERTION
    true = ets:update_element(FileSummaryEts, Right,
                              {#file_summary.left, Left}),
    %% ensure the double linked list is maintained
    true = case Left of
               undefined -> true; %% File is the eldest file (left-most)
               _         -> ets:update_element(FileSummaryEts, Left,
                                               {#file_summary.right, Right})
           end,
    true = ets:delete(FileSummaryEts, File),
    ok.

%%----------------------------------------------------------------------------
%% garbage collection / compaction / aggregation -- external
%%----------------------------------------------------------------------------

has_readers(File, #gc_state { file_summary_ets = FileSummaryEts }) ->
    [#file_summary { locked = true, readers = Count }] =
        ets:lookup(FileSummaryEts, File),
    Count /= 0.

combine_files(Source, Destination,
              State = #gc_state { file_summary_ets = FileSummaryEts,
                                  file_handles_ets = FileHandlesEts,
                                  dir              = Dir,
                                  msg_store        = Server }) ->
    [#file_summary {
       readers          = 0,
       left             = Destination,
       valid_total_size = SourceValid,
       file_size        = SourceFileSize,
       locked           = true }] = ets:lookup(FileSummaryEts, Source),
    [#file_summary {
       readers          = 0,
       right            = Source,
       valid_total_size = DestinationValid,
       file_size        = DestinationFileSize,
       locked           = true }] = ets:lookup(FileSummaryEts, Destination),

    SourceName           = filenum_to_name(Source),
    DestinationName      = filenum_to_name(Destination),
    {ok, SourceHdl}      = open_file(Dir, SourceName,
                                     ?READ_AHEAD_MODE),
    {ok, DestinationHdl} = open_file(Dir, DestinationName,
                                     ?READ_AHEAD_MODE ++ ?WRITE_MODE),
    TotalValidData = SourceValid + DestinationValid,
    %% if DestinationValid =:= DestinationContiguousTop then we don't
    %% need a tmp file
    %% if they're not equal, then we need to write out everything past
    %%   the DestinationContiguousTop to a tmp file then truncate,
    %%   copy back in, and then copy over from Source
    %% otherwise we just truncate straight away and copy over from Source
    {DestinationWorkList, DestinationValid} =
        load_and_vacuum_message_file(Destination, State),
    {DestinationContiguousTop, DestinationWorkListTail} =
        drop_contiguous_block_prefix(DestinationWorkList),
    case DestinationWorkListTail of
        [] -> ok = truncate_and_extend_file(
                     DestinationHdl, DestinationContiguousTop, TotalValidData);
        _  -> Tmp = filename:rootname(DestinationName) ++ ?FILE_EXTENSION_TMP,
              {ok, TmpHdl} = open_file(Dir, Tmp, ?READ_AHEAD_MODE++?WRITE_MODE),
              ok = copy_messages(
                     DestinationWorkListTail, DestinationContiguousTop,
                     DestinationValid, DestinationHdl, TmpHdl, Destination,
                     State),
              TmpSize = DestinationValid - DestinationContiguousTop,
              %% so now Tmp contains everything we need to salvage
              %% from Destination, and index_state has been updated to
              %% reflect the compaction of Destination so truncate
              %% Destination and copy from Tmp back to the end
              {ok, 0} = file_handle_cache:position(TmpHdl, 0),
              ok = truncate_and_extend_file(
                     DestinationHdl, DestinationContiguousTop, TotalValidData),
              {ok, TmpSize} =
                  file_handle_cache:copy(TmpHdl, DestinationHdl, TmpSize),
              %% position in DestinationHdl should now be DestinationValid
              ok = file_handle_cache:sync(DestinationHdl),
              ok = file_handle_cache:delete(TmpHdl)
    end,
    {SourceWorkList, SourceValid} = load_and_vacuum_message_file(Source, State),
    ok = copy_messages(SourceWorkList, DestinationValid, TotalValidData,
                       SourceHdl, DestinationHdl, Destination, State),
    %% tidy up
    ok = file_handle_cache:close(DestinationHdl),
    ok = file_handle_cache:close(SourceHdl),

    %% don't update dest.right, because it could be changing at the
    %% same time
    true = ets:update_element(
             FileSummaryEts, Destination,
             [{#file_summary.valid_total_size, TotalValidData},
              {#file_summary.file_size,        TotalValidData}]),

    Reclaimed = SourceFileSize + DestinationFileSize - TotalValidData,
    gen_server2:cast(Server, {combine_files, Source, Destination, Reclaimed}),
    safe_file_delete_fun(Source, Dir, FileHandlesEts).

delete_file(File, State = #gc_state { file_summary_ets = FileSummaryEts,
                                      file_handles_ets = FileHandlesEts,
                                      dir              = Dir,
                                      msg_store        = Server }) ->
    [#file_summary { valid_total_size = 0,
                     locked           = true,
                     file_size        = FileSize,
                     readers          = 0 }] = ets:lookup(FileSummaryEts, File),
    {[], 0} = load_and_vacuum_message_file(File, State),
    gen_server2:cast(Server, {delete_file, File, FileSize}),
    safe_file_delete_fun(File, Dir, FileHandlesEts).

load_and_vacuum_message_file(File, #gc_state { dir          = Dir,
                                               index_module = Index,
                                               index_state  = IndexState }) ->
    %% Messages here will be end-of-file at start-of-list
    {ok, Messages, _FileSize} =
        scan_file_for_valid_messages(Dir, filenum_to_name(File)),
    %% foldl will reverse so will end up with msgs in ascending offset order
    lists:foldl(
      fun ({Guid, TotalSize, Offset}, Acc = {List, Size}) ->
              case Index:lookup(Guid, IndexState) of
                  #msg_location { file = File, total_size = TotalSize,
                                  offset = Offset, ref_count = 0 } = Entry ->
                      ok = Index:delete_object(Entry, IndexState),
                      Acc;
                  #msg_location { file = File, total_size = TotalSize,
                                  offset = Offset } = Entry ->
                      {[ Entry | List ], TotalSize + Size};
                  _ ->
                      Acc
              end
      end, {[], 0}, Messages).

copy_messages(WorkList, InitOffset, FinalOffset, SourceHdl, DestinationHdl,
              Destination, #gc_state { index_module = Index,
                                       index_state  = IndexState }) ->
    Copy = fun ({BlockStart, BlockEnd}) ->
                   BSize = BlockEnd - BlockStart,
                   {ok, BlockStart} =
                       file_handle_cache:position(SourceHdl, BlockStart),
                   {ok, BSize} =
                       file_handle_cache:copy(SourceHdl, DestinationHdl, BSize)
           end,
    case
        lists:foldl(
          fun (#msg_location { guid = Guid, offset = Offset,
                               total_size = TotalSize },
               {CurOffset, Block = {BlockStart, BlockEnd}}) ->
                  %% CurOffset is in the DestinationFile.
                  %% Offset, BlockStart and BlockEnd are in the SourceFile
                  %% update MsgLocation to reflect change of file and offset
                  ok = Index:update_fields(Guid,
                                           [{#msg_location.file, Destination},
                                            {#msg_location.offset, CurOffset}],
                                           IndexState),
                  {CurOffset + TotalSize,
                   case BlockEnd of
                       undefined ->
                           %% base case, called only for the first list elem
                           {Offset, Offset + TotalSize};
                       Offset ->
                           %% extend the current block because the
                           %% next msg follows straight on
                           {BlockStart, BlockEnd + TotalSize};
                       _ ->
                           %% found a gap, so actually do the work for
                           %% the previous block
                           Copy(Block),
                           {Offset, Offset + TotalSize}
                   end}
          end, {InitOffset, {undefined, undefined}}, WorkList) of
        {FinalOffset, Block} ->
            case WorkList of
                [] -> ok;
                _  -> Copy(Block), %% do the last remaining block
                      ok = file_handle_cache:sync(DestinationHdl)
            end;
        {FinalOffsetZ, _Block} ->
            {gc_error, [{expected, FinalOffset},
                        {got, FinalOffsetZ},
                        {destination, Destination}]}
    end.
