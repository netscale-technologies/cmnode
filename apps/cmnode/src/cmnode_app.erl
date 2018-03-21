%%%-------------------------------------------------------------------
%% @doc cmnode public API
%% @end
%%%-------------------------------------------------------------------

-module(cmnode_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    cmnode_sup:start_link().

%%--------------------------------------------------------------------
stop(_State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================
