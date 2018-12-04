-module(cmcore_util).
-export([
         init/2,
         cmds/5,
         update/5,
         update_spec/5,
         decode/3
         %apply_effect/4
        ]).

init(#{ init := Init }=App, Config) -> update(App, Init, Config);
init(_, _) -> {ok, #{}, []}.

update_spec(#{ update := Updates, encoders := Encoders }, Msg, Data, Model, Config) ->
    case maps:get(Msg, Updates, undef) of
        undef ->
            {error, #{  update => not_implemented, msg => Msg }};
        Clauses ->
            %In = #{ model => Model, data => Data },
            In = maps:merge(Model, Data),
            case first_clause(Clauses, Encoders, In, Config) of
                none ->
                    {error, #{  update => none_applies, msg => Msg }};
                Spec ->
                    {ok, Spec}
            end
    end;

update_spec(_, Msg, _, _, _) ->
    {error, #{ update => not_implemented, msg => Msg }}.





first_clause([], _, _, _) -> none;
first_clause([#{ condition := Cond}=Spec|Rem], Encoders, In, Config) ->
    case cmeval:eval(Cond, Encoders, In, Config) of
        true -> Spec;
        false -> first_clause(Rem, Encoders, In, Config)
    end;

first_clause([Spec|_], _, _, _) ->
    Spec.

decode(#{ decoders := Decoders }, Data, Config) ->
    decode(Decoders, Data, Config);

decode([], _, _) -> {error, no_match};

decode([#{ msg := Msg, spec := Spec}|Rem], Data, Config) ->
    case cmdecode:decode(Spec, Data, Config) of
        no_match ->
            decode(Rem, Data, Config);
        {ok, Decoded} ->
            {ok, Msg, Decoded}
    end;

decode(_, _, _) -> {error, no_match}.

update(App, Spec, Config) -> update(App, Spec, Config, #{}).

update(App, Spec, Config, In) -> update(App, Spec, Config, In, {#{}, []}).

update(App, #{ model := M, cmds := C } = Spec, Config, In, {Model, Cmds}) ->
    case data_with_where(Spec, In, Model, Config) of 
        {ok, In2} ->
            case cmencode:encode(M, In2, Config) of
                {ok, M2} ->
                    M3 = maps:merge(Model, M2),
                    case resolve_cmds(App, C) of
                        {ok, C2} ->
                            {ok, M3, Cmds ++ C2};
                        {error, E} ->
                            {error, E}
                    end;
                {error, E} -> 
                    {error, E}
            end;
        Other ->
            Other
    end;

update(_, Spec, _, _, _) -> {error, {invalid_update, Spec}}.


data_with_where(#{ where := WhereSpec }, Data, Model, Config) ->
    In = maps:merge(Model, Data),
    case cmencode:encode(WhereSpec, In, Config) of 
        {ok, Where} ->
            {ok, maps:merge(In, Where)};
        Other ->
            Other
    end;
        
data_with_where(_, Data, Model, _) -> {ok, maps:merge(Model, Data)}.

resolve_cmds(App, Cmds) ->
    resolve_cmds(App, Cmds, []).

resolve_cmds(_, [], Out) -> {ok, lists:reverse(Out)};
resolve_cmds(App, [Cmd|Rem], Out) ->
    case resolve_cmd(App, Cmd) of
        {ok, Cmd2} ->
            resolve_cmds(App, Rem, [Cmd2|Out]);
        {error, E} -> {error, E}
    end.

resolve_cmd(#{ encoders := Encoders }, #{ encoder := Enc }=Cmd) ->
    case maps:get(Enc, Encoders, undef) of
        undef ->
            {error, unknown_encoder(Enc) };
        Encoder ->
            {ok, Cmd#{ encoder => Encoder }}
    end;

resolve_cmd(_, #{ encoder := Enc }) ->
    {error, unknown_encoder(Enc)};

resolve_cmd(_, #{ effect := _ }=Cmd) ->
    {ok, Cmd };

resolve_cmd(_, Cmd) ->
    {error, {invalid_cmd, Cmd}}.

unknown_encoder(Enc) ->
    #{ encoder => Enc,
       status => undefined }.


cmds([], _, _, _, _) -> ok;
cmds([#{ effect := Effect,
         encoder := Spec }|Rem], Model, Config, Pid, Log) ->
    case cmencode:encode(Spec, Model, Config) of
        {error, Error} ->
            cmkit:danger({cmcore, Effect, Spec, Error});
        {ok, Data} ->
            apply_effect(Effect, Data, Pid, Log)
    end,
    cmds(Rem, Model, Config, Pid, Log);

cmds([#{ effect := Effect}|Rem], Model, Config, Pid, Log) ->
    apply_effect(Effect, nothing, Pid, Log),
    cmds(Rem, Model, Config, Pid, Log).

apply_effect(Effect, Data, Pid, _Log) ->
    case cmconfig:effect(Effect) of
        {error, not_found} ->
            cmkit:danger({cmcore, not_such_effect, Effect, Data});
        {ok, Mod} ->
            spawn(fun() ->
                          Mod:effect_apply(Data, Pid)
                  end)
    end,
    ok.
