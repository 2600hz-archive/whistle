%% ---
%%  Excerpted from "Programming Erlang",
%%  published by The Pragmatic Bookshelf.
%%  Copyrights apply to this code. It may not be used to create training material, 
%%  courses, books, articles, and the like. Contact us if you are in doubt.
%%  We make no guarantees that this code is fit for any purpose. 
%%  Visit http://www.pragmaticprogrammer.com/titles/jaerlang for more book information.
%%---

-module(indexer_trigrams).
-export([for_each_trigram_in_the_english_language/2,
	 make_tables/0, timer_tests/0,
	 open/0, close/1, is_word/2,
	 howManyTrigrams/0, 
	 make_dict/0, make_ordered_set/0, makeSet/0,
	 lookup_all_ets/2, lookup_all_dict/2
	]).
-import(lists, [reverse/1]).



make_tables() ->  
    io:format("Building trigrams -- make take some time~n"),
    makeSet().



make_ordered_set() -> makeAset(ordered_set, "trigramsOS.tab").
makeSet()        -> makeAset(set, "trigramsS.tab").

makeAset(Type, FileName) ->		
    Tab = ets:new(table, [Type]),
    F = fun(Str, _) -> ets:insert(Tab, {list_to_binary(Str)}) end,
    for_each_trigram_in_the_english_language(F, 0),
    ets:tab2file(Tab, FileName),
    Size = ets:info(Tab, size),
    ets:delete(Tab),
    Size.



make_dict() ->
    D = dict:new(),
    F = fun(Str, Dict) -> dict:store(list_to_binary(Str),[],Dict) end,
    D1 = for_each_trigram_in_the_english_language(F, D),
    file:write_file("trigrams.dict", [term_to_binary(D1)]).



timer_tests() ->
    time_lookup_set("Ordered Set", "trigramsOS.tab"),
    time_lookup_set("Set", "trigramsS.tab"),
    time_lookup_dict().

time_lookup_set(Type, File) ->
    {ok, Tab} = ets:file2tab(File),
    L = ets:tab2list(Tab),
    Size = length(L),
    {M, _} = timer:tc(?MODULE, lookup_all_ets, [Tab, L]),
    io:format("~s lookup=~p micro seconds~n",[Type, M/Size]),
    ets:delete(Tab).

lookup_all_ets(Tab, L) ->
    lists:foreach(fun({K}) -> ets:lookup(Tab, K) end, L).

time_lookup_dict() ->
    {ok, Bin} = file:read_file("trigrams.dict"),
    Dict = binary_to_term(Bin),
    Keys = [Key || {Key,_} <- dict:to_list(Dict)],
    Size = length(Keys),
    {M, _} = timer:tc(?MODULE, lookup_all_dict, [Dict, Keys]),
    io:format("Dict lookup=~p micro seconds~n",[M/Size]).

lookup_all_dict(Dict, L) ->
    lists:foreach(fun(Key) -> dict:find(Key, Dict) end, L).


howManyTrigrams() ->
    F = fun(_, N) -> 1 + N  end,
    for_each_trigram_in_the_english_language(F, 0).
    
%% An iterator that iterates through all trigrams in the language

for_each_trigram_in_the_english_language(F, A0) ->
    {ok, Bin0} = file:read_file("../354984si.ngl.gz"),
    Bin = zlib:gunzip(Bin0),
    scan_word_list(binary_to_list(Bin), F, A0).

scan_word_list([], _, A) ->
    A;
scan_word_list(L, F, A) ->
    {Word, L1} = get_next_word(L, []),
    A1 = scan_trigrams([$\s|Word], F, A),
    scan_word_list(L1, F, A1).

%% scan the word looking for \r\n
%% the second argument is the word (reversed) so it
%% has to be reversed when we find \r\n or run out of characters

get_next_word([$\r,$\n|T], L) -> {reverse([$\s|L]), T};
get_next_word([H|T], L)       -> get_next_word(T, [H|L]);
get_next_word([], L)          -> {reverse([$\s|L]), []}.

scan_trigrams([X,Y,Z], F, A) ->
    F([X,Y,Z], A);
scan_trigrams([X,Y,Z|T], F, A) ->
    A1 = F([X,Y,Z], A),
    scan_trigrams([Y,Z|T], F, A1);
scan_trigrams(_, _, A) ->
    A.


%% access routines
%%   open() -> Table
%%   close(Table)
%%   is_word(Table, String) -> Bool


is_word(Tab, Str) -> is_word1(Tab, "\s" ++ Str ++ "\s").

is_word1(Tab, [_,_,_]=X) -> is_this_a_trigram(Tab, X);
is_word1(Tab, [A,B,C|D]) ->
    case is_this_a_trigram(Tab, [A,B,C]) of
	true  -> is_word1(Tab, [B,C|D]);
	false -> false
    end;
is_word1(_, _) ->
    false.

is_this_a_trigram(Tab, X) ->
    case ets:lookup(Tab, list_to_binary(X)) of
	[] -> false;
	_  -> true
    end.

open() ->
    {ok, I} = ets:file2tab(filename:dirname(code:which(?MODULE)) 
			   ++ "/trigramsS.tab"),
    I.

close(Tab) -> ets:delete(Tab).

