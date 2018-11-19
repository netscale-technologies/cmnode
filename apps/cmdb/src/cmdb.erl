-module(cmdb).
-export([
         reset/1,
         del/2,
         put/2,
         get/2,
         get/3,
         get/4,
         between/5,
         map/4,
         map/5,
         pipeline/2
        ]).

reset(Name) -> 
    cmdb_util:reset(cmdb_config:storage(Name), Name).

del(Name, Entries) ->
    cmdb_util:del(cmdb_config:storage(Name), Name, Entries).

put(Name, Entries) -> 
    cmdb_util:put(cmdb_config:storage(Name), Name, Entries).

get(Name, S, P) -> 
    merge(cmdb_util:inspect(Name, S, P)).

get(Name, S) -> 
    merge(cmdb_util:inspect(Name, S)).

get(Name, S, P, O) ->
    merge(cmdb_util:inspect(Name, S, P, O)).

between(Name, S, P, O1, O2) ->
    EndFun = fun({S0, P0, O0, H, T}, V) when S0 =:= S andalso
                                             P0 =:= P andalso
                                             O0 < O2 -> {ok, {S0, P0, O0, H, T, V}};
                (_, _) -> stop
             end,

    merge(cmdb_util:fold(Name, {S, P, O1, 0, 0}, EndFun)).

map(Name, S, Match, Merge) ->
    cmdb_util:map(cmdb_config:storage(Name), Name, S, Match, Merge).

map(Name, S, P, Match, Merge) ->
    cmdb_util:map(cmdb_config:storage(Name), Name, S, P, Match, Merge).

pipeline(Name, P) ->
    cmdb_util:pipeline(cmdb_config:storage(Name), Name, P).

merge({ok, Entries}) -> {ok, cmdb_util:merge(Entries)};
merge(Other) -> Other.
