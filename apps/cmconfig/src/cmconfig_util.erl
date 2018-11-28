-module(cmconfig_util).
-export([plural/1,
         filenames/0,
         filenames/1,
         reload/0,
         reload/1,
         compiled/1,
         parse/0,
         parse/1,
         rank/1,
         ranked/1,
         deps/1
        ]).
-define(TYPES, [effect,
                port,
                template,
                module,
                app,
                theme,
                queue,
                settings,
                cron,
                test,
                bucket,
                task]).

plural(settings) -> "settings";
plural(T) -> cmkit:to_list(cmkit:fmt("~ss", [T])).

filenames(T) when is_list(T) ->
    lists:merge(lists:map(fun filenames/1, T));

filenames(T) when is_atom(T) ->
    cmkit:files(filename:join([
                               cmkit:etc(),
                               plural(T)
                              ]), ".yml").

filenames() ->
    cmkit:files(cmkit:etc(), ".yml").

compile_plan(module) -> [settings, module, app, port];
compile_plan(app) -> [settings, app, port];
compile_plan(settings) -> [settings, module, app, port];
compile_plan(T) when is_atom(T) -> [T];
compile_plan(B) when is_binary(B) -> compile_plan(cmkit:to_atom(B)).

reload() ->
    reload(?TYPES, fun parse/0).

reload(T) ->
    Types = compile_plan(T),
    reload(Types, fun() ->
                        parse(Types)
                end).

reload(Types, SpecsFun) ->
    S0 = cmkit:micros(),
    case SpecsFun() of 
        {ok, Specs} ->
    
            E1 = cmkit:elapsed(S0),
            cmkit:log({cmconfig, yamls, parsed}),
            I = compiled(sorted(ranked(Specs))),
            E2 = cmkit:elapsed(S0),
            cmkit:log({cmconfig, yamls, indexed}),
            lists:foreach(fun(T) ->
                                  compile_forms(T, I)     
                          end, Types),
            E3 = cmkit:elapsed(S0),
            cmkit:log({cmconfig, yamls, compiled, stats(I), #{ parse => E1,
                                                               index => E2-E1,
                                                               compile => E3-E2,
                                                               total => E3}});
        Other ->
            cmkit:danger({cmconfig, reload, Types, Other}),
            Other
    end.


compile_forms(T, Index) -> 
    cache(T, Index).

stats(Index) ->
    maps:fold(fun(Type, SubIndex, Acc) ->
                      case map_size(SubIndex) of 
                        0 -> Acc;
                        C -> Acc#{ Type => C }
                      end
              end, #{}, Index).

cache(T, Index) ->
    I = maps:get(T, Index),
    cmkit:set_app_env(cmconfig, T, maps:values(I)),
    cache(T, maps:keys(I), I).

cache(_, [], _) -> ok;
cache(T, [K|Rem], I) ->
    cmkit:set_app_env(cmconfig, T, K, maps:get(K, I)),
    cache(T, Rem, I).


ranked(Specs) ->
    lists:map(fun ranked_spec/1, Specs).

sorted(Specs) -> 
    lists:sort(fun(#{ <<"rank">> := R1}, #{ <<"rank">> := R2 }) ->
                R1 =< R2
               end, Specs).

compiled(Specs) ->
    Index = lists:foldl(fun(T, I) ->
                                I#{ T => #{}}
                        end, #{}, ?TYPES),
    compiled(Specs, Index).

compiled([], Index) -> Index;
compiled([Spec|Rem], Index) ->
    case compile(Spec, Index) of 
        {ok, #{ type := Type, 
                name := Name } = Compiled} -> 
            I0 = maps:get(Type, Index),
            compiled(Rem, Index#{ Type => I0#{ Name => Compiled} });
        _ -> 
            cmkit:warning({cmconfig, compile_error, Spec}),
            compiled(Rem, Index)
    end.
    
parse() ->
    specs(filenames()).
    
parse(T) ->
    specs(filenames(T)).

specs(Filenames) ->
    specs(Filenames, []).

specs([], Specs) -> {ok, Specs};
specs([F|Rem], Specs) ->
    case cmkit:yaml(F) of 
        {ok, S} -> 
            specs(Rem, [S|Specs]);
        {error, E} ->
            {error, #{ yaml => F,
                       error => E }}
    end.

rank(port) -> 3;
rank(app) -> 2;
rank(module) -> 1;
rank(_) -> 0.

ranked_spec(#{ <<"type">> := Type }=Spec) -> 
    T = cmkit:to_atom(Type),
    Children = case deps(Spec) of 
                   {ok, _, _, Deps} -> length(Deps);
                   _ -> 0
               end,
    Spec#{ <<"rank">> => cmkit:to_float(rank(T), Children)}. 

compile(#{ <<"type">> := <<"port">> }=Spec, Index) -> {ok, compile_port(Spec, Index)};
compile(#{ <<"type">> := <<"app">> }=Spec, Index) -> {ok, compile_app(Spec, Index)};
compile(#{ <<"type">> := <<"bucket">> }=Spec, Index) -> {ok, compile_bucket(Spec, Index)};
compile(#{ <<"type">> := <<"template">> }=Spec, Index) -> {ok, compile_template(Spec, Index)};
compile(#{ <<"type">> := <<"module">> }=Spec, Index) -> {ok, compile_module(Spec, Index)};
compile(#{ <<"type">> := <<"test">> }=Spec, Index) -> {ok, compile_test(Spec, Index)};
compile(#{ <<"type">> := <<"queue">> }=Spec, Index) -> {ok, compile_queue(Spec, Index)};
compile(#{ <<"type">> := <<"settings">> }=Spec, Index) -> {ok, compile_settings(Spec, Index)};
compile(#{ <<"type">> := <<"cron">> }=Spec, Index) -> {ok, compile_cron(Spec, Index)};
compile(#{ <<"type">> := <<"task">> }=Spec, Index) -> {ok, compile_task(Spec, Index)};
compile(#{ <<"type">> := <<"theme">> }=Spec, Index) -> {ok, compile_theme(Spec, Index)};

compile(Spec, _) ->
    cmkit:danger({cmconfig, unknown_spec, Spec}),
    {error, Spec}.

deps(#{ <<"type">> := T, 
        <<"name">> := N }=Spec) -> 
    Type = cmkit:to_atom(T),
    Name = cmkit:to_atom(N),
    {ok, Type, Name, cmkit:distinct(deps(Type, Spec))}.

deps(app, #{ <<"spec">> := #{
                 <<"modules">> := Modules }}) -> 
    lists:map(fun(Name) ->
                      {module, cmkit:to_atom(Name)}
              end, Modules);

deps(port, #{ <<"spec">> := #{
                  <<"apps">> := Apps }}) when is_map(Apps) -> 
    lists:map(fun(Name) ->
                      {app, cmkit:to_atom(Name)}
              end, maps:keys(Apps));

deps(module, #{ <<"spec">> := 
                #{ <<"encoders">> := Encoders }}) when is_map(Encoders) ->
    module_deps(maps:values(Encoders), []);

deps(settings, #{ <<"spec">> := 
                    #{ <<"merge">> := Settings }}) when is_list(Settings)->
    lists:foldr(fun(#{ <<"settings">> := Name }, Deps) ->
                        [{settings, cmkit:to_atom(Name)}|Deps];
                   (_, Deps) ->
                        Deps
                end, [], Settings);

deps(_, _) -> [].

module_deps([], Deps) -> Deps;
module_deps([#{<<"object">> := Spec}|Rem], Deps) when is_map(Spec) ->
    module_deps(Rem, modules_from_object_spec(maps:keys(Spec), Spec, []) ++ Deps); 

module_deps([_|Rem], Deps) -> module_deps(Rem, Deps). 

modules_from_object_spec([], _, Mods) -> Mods;
modules_from_object_spec([K|Rem], Spec, Mods) ->
    case maps:get(K, Spec) of
        #{ <<"spec">> := 
           #{ <<"modules">> := MoreMods }} ->
            modules_from_object_spec(Rem, Spec, lists:map(fun(Name) ->
                                                                  {module, cmkit:to_atom(Name)}     
                                                          end, MoreMods)
                                     ++ Mods);
        _ ->
            modules_from_object_spec(Rem, Spec, Mods)
    end.

compile_port(#{ <<"name">> := Name,
                <<"rank">> := Rank,
                <<"spec">> := #{
                    <<"port">> := Port,
                    <<"acceptors">> := Acceptors,
                    <<"apps">> := Apps }}, _) ->

    #{ name => compile_keyword(Name),
       type => port,
       rank => Rank,
       port  => Port,
       acceptors => Acceptors,
       apps => compile_port_apps(Apps) }.

compile_port_apps(Apps) ->
    maps:fold(fun(Name, Mounts, List) ->
                      [compile_port_app(Name, Mounts)|List]
              end, [], Apps).

compile_port_app(Name, Mounts) ->
    #{ name => compile_keyword(Name),
       mounts => compile_port_app_mounts(Mounts) }.

compile_port_app_mounts(Mounts) when is_map(Mounts) ->
    maps:fold(fun(Transport, Path, List) ->
                      [#{ transport => compile_keyword(Transport),
                          path => cmkit:to_list(Path) }|List]
              end, [], Mounts).

compile_settings(#{ <<"name">> := Name,
                    <<"rank">> := Rank,
                    <<"spec">> := Spec }, Index) ->
    #{ type => settings,
       rank => Rank,
       name => cmkit:to_atom(Name),
       spec => compile_term(Spec, Index) }.

compile_theme(#{ <<"name">> := Name,
                 <<"rank">> := Rank,
                 <<"spec">> := Spec }, Index) ->

    C = compile_term(maps:get(<<"colors">>, Spec, #{}), Index),
    S = compile_term(maps:get(<<"selectors">>, Spec, []), Index),
    F = compile_term(maps:get(<<"fonts">>, Spec, #{}), Index),
    FS = compile_term(maps:get(<<"font-sizes">>, Spec, #{}), Index),

    #{ type => theme,
       rank => Rank,
       name => cmkit:to_atom(Name),
       spec => #{ colors => C, fonts => F, font_sizes => FS, selectors => S }}.

compile_queue(#{ <<"name">> := Name,
                 <<"rank">> := Rank,
                 <<"spec">> := #{
                     <<"concurrency">> := C,
                     <<"max">> := M
                    }}, _) ->

    Worker = cmkit:to_atom(cmkit:bin_join([Name, <<"queue">>], <<"_">>)),

    #{ type => queue,
       rank => Rank,
       name => cmkit:to_atom(Name),
       worker => Worker, 
       capacity => #{ max => M, concurrency => C }}.

compile_cron(#{ <<"name">> := Name,
                <<"rank">> := Rank,
                <<"spec">> := #{ <<"schedule">> := Schedule,
                                 <<"jobs">> := Jobs }}, Index) ->

    CronName = cmkit:to_atom(Name),
    #{ type => cron,
       rank => Rank,
       name => CronName,
       schedule  => compile_cron_schedule(Schedule),
       jobs => compile_cron_jobs(Jobs, Index) 
     }.

compile_cron_schedule(#{ <<"once">> := Secs}) ->
    #{ type => once,
       secs => Secs };

compile_cron_schedule(#{ <<"pm">> := #{ <<"hour">> := Hour,
                                        <<"min">> := Min }}) ->
    #{ type => daily,
       hour => Hour,
       min => Min,
       period => pm };

compile_cron_schedule(#{ <<"am">> := #{ <<"hour">> := Hour,
                                        <<"min">> := Min }}) ->
    #{ type => daily,
       hour => Hour,
       min => Min,
       period => am }.

compile_cron_jobs(Specs, Index) ->
    lists:map(fun(Spec) ->
                compile_cron_job(Spec, Index)
              end, Specs).


compile_cron_job(#{ <<"module">> := Mod,
                     <<"fun">> := Fun,
                     <<"args">> := Args }, Index) ->
    
    {ok, EncodedArgs } = cmencode:encode(#{ type => list,
                                            value => compile_terms(Args, Index) }),

    #{ module => cmkit:to_atom(Mod),
       function => cmkit:to_atom(Fun),
       args => EncodedArgs
     };

compile_cron_job(#{ <<"task">> := Name,
                     <<"settings">> := Settings }, Index) ->
    
    #{ task=> compile_term(Name, Index),
       settings => compile_term(Settings, Index)
     }.

compile_task(#{ <<"name">> := Name,
                <<"rank">> := Rank,
                <<"spec">> := Items }, Index) ->

    #{ type => task,
       rank => Rank,
       name => cmkit:to_atom(Name),
       items => compile_terms(Items, Index)
     }.

compile_template(#{ <<"name">> := Name,
                    <<"rank">> := Rank,
                    <<"spec">> := #{
                        <<"contents">> := Contents }}, _) ->

    #{   type => template,
         rank => Rank,
         name => cmkit:to_atom(Name),
         contents => Contents }.


compile_module(#{ <<"name">> := Name,
                  <<"rank">> := Rank,
                  <<"spec">> := Spec }, Index) ->


    #{ spec := CompiledSpec } = compile_spec(Spec, Index),
    maps:merge(CompiledSpec,  #{
                 name => cmkit:to_atom(Name),
                 type => module,
                 rank => Rank
                }).


app_settings_ref(Name) when is_binary(Name) ->
    SettingsName = cmkit:to_atom(Name),
    {SettingsName, SettingsName};

app_settings_ref(#{ <<"as">> := Alias, <<"name">> := Name}) ->
    {cmkit:to_atom(Alias), cmkit:to_atom(Name)}.


app_config_with_settings([], _,  _, Out) -> Out;
app_config_with_settings([N|Rem], App, Settings, Out) ->
    {Alias, SettingsName} = app_settings_ref(N),
    case maps:get(SettingsName, Settings, undef) of 
        undef -> 
            cmkit:warning({app, App, config, no_such_settings, SettingsName}),
            app_config_with_settings(Rem, App, Settings, Out);
        #{ spec := Spec } ->
            case cmencode:encode(Spec) of 
                {ok, Encoded} ->
                    app_config_with_settings(Rem, App, Settings, Out#{ Alias => Encoded});
                Other ->
                    cmkit:warning({app, App, config, invalid_settings, SettingsName, Other}),
                    app_config_with_settings(Rem, App, Settings, Out)
            end
    end.

compile_app_config(App, #{ <<"settings">> := Names }=Spec, 
                   #{ settings := Settings }=Index) when is_list(Names)  ->
    BaseConfig = compile_app_config(App, maps:without([<<"settings">>], Spec), Index),
    app_config_with_settings(Names, App, Settings, BaseConfig);

compile_app_config(_, Other, Index) ->
     compile_config(Other, Index).

compile_app(#{ <<"name">> := Name,
               <<"rank">> := Rank,
               <<"category">> := Cat,
               <<"spec">> := #{
                   <<"modules">> := Modules 
                  } = Spec
             }, #{ module := Mods}=Index) ->

    AppName = cmkit:to_atom(Name),
    ResolvedModules = resolve_modules(Modules, Mods),
    
    AppConfig = compile_app_config(AppName, maps:get(<<"config">>, Spec, #{}), Index),

    #{ name => AppName,
       type => app,
       rank => Rank,
       modules => lists:map(fun(#{ status := unknown }=M) ->
                                    M;
                               (#{ name := ModName }) ->
                                    #{ name => ModName,
                                       status => resolved
                                     }
                            end, ResolvedModules),
       config => AppConfig,
       debug => compile_keyword(maps:get(<<"debug">>, Spec, <<"false">>)),
       timeout => cmkit:to_number(maps:get(<<"timeout">>, Spec, <<"10000">>)),
       category => compile_keyword(Cat),
       spec => compile_modules(ResolvedModules, #{})
     }.


compile_bucket(#{ <<"name">> := Name,
                  <<"rank">> := Rank,
                  <<"spec">> := #{ 
                      <<"storage">> := Storage
                     } = Spec}, _) ->

    #{ type => bucket,
       rank => Rank,
       name => cmkit:to_atom(Name),
       storage =>  cmkit:to_atom(Storage),
       debug =>  cmkit:to_atom(maps:get(<<"debug">>, Spec, <<"false">>))
     }.

compile_test(#{ <<"name">> := Name,
                <<"rank">> := Rank,
                <<"spec">> := Spec
              }, Index) ->


    Config = maps:get(<<"config">>, Spec, #{}),
    Facts = maps:get(<<"facts">>, Spec, #{}),
    Scenarios = compile_scenarios(maps:get(<<"scenarios">>, Spec, []), Index),
    Backgrounds = maps:get(<<"backgrounds">>, Spec, []),
    Procedures = maps:get(<<"procedures">>, Spec, []),
    Steps = maps:get(<<"steps">>, Spec, []),

    #{ type => test,
       rank => Rank,
       name => cmkit:to_atom(Name),
       config => compile_config(Config, Index),
       scenarios => Scenarios,
       steps => compile_steps(Steps, Index),
       procedures => compile_procedures(Procedures, Index),
       backgrounds => compile_backgrounds(Backgrounds, Scenarios, Index),
       facts => compile_term(Facts, Index)
     }.

compile_procedures(Specs, Index) ->
    lists:map(fun(S) -> 
                      compile_procedure(S, Index)
              end, Specs).

compile_procedure(#{ <<"name">> := Name,
                     <<"spec" >> := Spec,
                     <<"as">> := As }, Index) ->
    #{ name => cmkit:to_atom(Name),
       spec => compile_term(Spec, Index),
       as => compile_term(As, Index) };

compile_procedure(#{ <<"name">> := Name,
                     <<"spec" >> := Spec}, Index) ->
    #{ name => cmkit:to_atom(Name),
       spec => compile_term(Spec, Index) }.

compile_scenarios(Specs, Index) -> 
    lists:map(fun(S) ->
                      compile_scenario(S, Index)
              end, Specs).

compile_scenario(#{ <<"title">> := Title }=Spec, Index) ->

    Tags = maps:get(<<"tags">>, Spec, []),
    Backgrounds = maps:get(<<"backgrounds">>, Spec, []),
    Steps =  maps:get(<<"steps">>, Spec, []),

    #{ title => Title,
       tags => compile_tags(Tags),
       backgrounds => Backgrounds,
       steps => compile_steps(Steps, Index)
     }.

compile_background(#{ <<"title">> := Title,
                      <<"steps">> := Steps }=Spec, Scenarios, Index) ->

    Tags = maps:get(<<"tags">>, Spec, []),

    RelatedScenarios = lists:filter(fun(#{ backgrounds := Backgrounds }) ->
                                            lists:any(fun(BackgroundTitle) ->
                                                              BackgroundTitle =:= Title
                                                      end, Backgrounds)
                                    end, Scenarios),


    #{ title => Title,
       tags => compile_tags(Tags),
       scenarios => RelatedScenarios,
       steps => compile_steps(Steps, Index)
     }.


compile_backgrounds(Specs, Scenarios, Index) ->
    lists:foldl(fun(Spec, Out) -> 
                        #{ title := Title } = Compiled = compile_background(Spec, Scenarios, Index),
                        Out#{ Title => Compiled } 
                end, #{}, Specs).

compile_tags(Tags) when is_list(Tags) ->
    lists:map(fun cmkit:to_atom/1, Tags);

compile_tags(Tags) when is_binary(Tags) ->
    F = fun(V) -> cmkit:to_atom(cmkit:bin_trim(V)) end,
    lists:map(F, cmkit:bin_split(Tags, <<",">>));

compile_tags(Spec) ->
    cmkit:danger({cmconfig, compile, invalid_tags, Spec}),
    [].

compile_steps(Steps, Index) -> 
    compile_steps(Steps, Index, []).

compile_steps([], _, Out) -> lists:reverse(Out);
compile_steps([Step|Rem], Index, Out) ->
    compile_steps(Rem, Index, [compile_step(Step, Index)|Out]).

compile_step(#{ <<"title">> := Title }=Spec, Index) ->
    Expr = compile_term(Spec, Index),
    Expr2 = Expr#{ title => Title },
    Expr3 = case maps:get(<<"as">>, Spec, undef) of
                undef -> Expr2;
                AsSpec -> 
                    Expr2#{ as => compile_term(AsSpec, Index) }
            end,
    Expr3;

compile_step(#{ <<"ref">> := Title }, Index)  ->
    compile_step(Title, Index);

compile_step(Title, _) when is_binary(Title) ->
    #{ ref => Title }.



compile_spec(#{ <<"settings">> := Settings,
                <<"modules">> := Modules}, #{ module := Mods }=Index) when is_list(Modules) ->
    
    #{ settings => compile_term(Settings, Index),
       spec => compile_modules(resolve_modules(Modules, Mods), #{})
     };

compile_spec(#{ <<"modules">> := Modules}, #{ module := Mods }) when is_list(Modules) ->
    #{ spec => compile_modules(resolve_modules(Modules, Mods), #{}) };

compile_spec(Spec, Index) ->

    Keys = [<<"decoders">>, <<"encoders">>, <<"init">>,
            <<"update">>, <<"views">>, <<"effects">> ],

    Contents = lists:foldl(fun(Key, C0) ->
                                   Term = #{ Key => maps:get(Key, Spec, #{})},
                                   case compile_term(Term, Index) of 
                                       [] -> C0;
                                       [_|_]=Other -> C0#{ compile_keyword(Key) => Other };
                                       Map when map_size(Map) =:= 0 -> C0;
                                       Other -> C0#{ compile_keyword(Key) => Other }
                                   end
                           end, #{}, Keys),

    #{ spec => Contents }.

compile_config(Spec, Index) -> 
    case cmencode:encode(compile_object(Spec, Index)) of 
        {ok, Config} -> Config;
        {error, E} -> 
            cmkit:warning({cmconfig, invalid_config, Spec, E}),
            #{}
    end.

compile_modules([], #{ decoders := Decs }=Spec) -> 
    Spec#{ decoders => sort_decoders(Decs) };

compile_modules([], Spec) -> Spec;

compile_modules([ModSpec|Rest], Spec) when is_map(ModSpec) ->
    compile_modules(Rest, merge_spec([decoders, 
                                      encoders, 
                                      init, 
                                      update, 
                                      views, 
                                      effects
                                     ], ModSpec, Spec));


compile_modules([_|Rest], Spec) -> 
    compile_modules(Rest, Spec).


merge_spec([], _, Spec) -> Spec;
merge_spec([decoders|Rem], Spec, Spec0) ->
    Decs0 = maps:get(decoders, Spec0, []),
    Decs = maps:get(decoders, Spec, []),
    merge_spec(Rem, Spec, maps:put(decoders, Decs ++ Decs0, Spec0));

merge_spec([init|Rem], 
           #{ init := [ #{ model := Model, cmds := Cmds }]}=Spec, 
           #{ init := #{ model := Model0, cmds := Cmds0 }}=Spec0) ->
    merge_spec(Rem, Spec, 
               maps:put(init, #{ model => merge_model_spec(Model, Model0),
                                 cmds => merge_cmds_spec(Cmds, Cmds0) 
                               }, Spec0));

merge_spec([init|Rem], 
           #{ init := [ #{ model := Model, cmds := Cmds }]}=Spec, Spec0) ->
    merge_spec(Rem, Spec, 
               maps:put(init, #{ model => Model, 
                                 cmds => Cmds 
                               }, Spec0));

merge_spec([update|Rem], Spec, Spec0) ->
    merge_spec(Rem, Spec, 
               maps:put(update, merge_updates_spec( 
                                  maps:get(update, Spec, #{}), 
                                  maps:get(update, Spec0, #{})), Spec0));

merge_spec([Key|Rem], Spec, Spec0) ->
    merge_spec(Rem, Spec, 
               maps:put(Key, maps:merge(maps:get(Key, Spec0, #{}),  maps:get(Key, Spec, #{})), Spec0)).

merge_model_spec(#{ spec := S1 }, #{ spec := S2}) -> 
    #{ type => object,
       spec => cmkit:merge(S2, S1) }.

merge_cmds_spec(Cmds1, Cmds2) -> Cmds1 ++ Cmds2. 

merge_updates_spec(Updates1, Updates2) when map_size(Updates2) =:= 0 -> Updates1;
merge_updates_spec(Updates1, Updates2) ->
    merge_updates_spec(maps:keys(Updates1), Updates1, Updates2).

merge_updates_spec([], _, Out) -> Out;
merge_updates_spec([K|Rem], U1, U2) ->
    merge_updates_spec(Rem, U1, 
                       maps:put(K, maps:get(K, U2, []) ++ maps:get(K, U1), U2)).

compile_option(#{ <<"when">> := When } = Spec, Index) ->

    #{ type => condition,
       condition => compile_term(When, Index),
       spec => compile_term(maps:without([<<"when">>], Spec), Index) 
     };

compile_option(Spec, Index) ->

    #{ type => condition,
       condition => #{ type => true },
       spec => compile_term(Spec, Index) 
     }.

compile_terms(Specs, Index) -> 
    lists:map(fun(S) -> compile_term(S, Index) end, Specs).


to_key_path(Bin) when is_binary(Bin) -> Bin;

to_key_path(#{ in := In } = Spec) ->
    InPath = to_key_path(In),
    KeyPath = to_key_path(maps:without([in], Spec)),
    <<InPath/binary, ".", KeyPath/binary>>;

to_key_path(#{ key := Key }) when is_binary(Key) or is_atom(Key) ->
    cmkit:to_bin(Key).

is_key_path(Term) when is_binary(Term) ->
    case binary:match(Term, <<".">>) of 
        nomatch ->
            case binary:match(Term, <<"{{">>) of 
                nomatch ->
                    false;
                _ ->
                    true
            end;
        _ ->
            true
    end;

is_key_path(_) -> false.


compile_key_path(Term) ->
    Parts = cmkit:bin_split(Term, <<".">>),
    compile_key_path_parts(lists:reverse(Parts)).

compile_key_path_parts([]) -> none;

compile_key_path_parts([P|Rem]) ->
    Spec0 = compile_key_path_part(P),
    Spec = case compile_key_path_parts(Rem) of 
        none ->
            Spec0;
        In ->
            Spec0#{ in => In }
    end,
    Spec.

compile_key_path_part(P) ->
    case re:split(P, "{{(\s*)(.*?)(\s*)}}") of 
        [_, _, Path, _, _] ->
            #{ key => compile_key_path(Path) };
        _ ->
            case cmkit:bin_split(P, <<"||">>) of
                [Single] ->
                    #{ key => cmkit:to_atom(Single)};
                [Key|[Default|_]] ->
                    #{ key => cmkit:to_atom(cmkit:bin_trim(Key)),
                       default => cmkit:bin_trim(Default) }
            end
    end.



compile_term(#{ <<"dump">> := Spec } = Map, _Index) when is_binary(Spec) and map_size(Map) =:= 1 ->
    #{ type => dump,
       spec => compile_keyword(Spec) };

compile_term(#{ <<"dump">> := Spec } = Map, Index) when map_size(Map) =:= 1 ->
    #{ type => dump,
       spec => compile_term(Spec, Index) };

compile_term(#{ <<"settings">> := Name }, #{ settings := Settings }) when is_binary(Name) ->
    S = cmkit:to_atom(Name),
    case maps:get(S, Settings, undef) of 
        undef ->
            cmkit:warning({cmconfig, compile, no_such_settings, Name,
                            maps:keys(Settings)}),
            #{ type => object,
               spec => #{ S => #{} } };
        #{ name := S,
           spec := Spec0 } ->
            #{ type => object,
               spec => #{ S => Spec0 }}
    end;



compile_term(#{ <<"decoders">> := Decs }, Index) ->
    compile_decoders(Decs, Index);

compile_term(#{ <<"encoders">> := Encs }, Index) ->
    compile_encoders(Encs, Index);

compile_term(#{ <<"effect">> := Effect, 
                <<"encoder">> := Encoder }, _) when is_binary(Effect) andalso is_binary(Encoder)->
    #{ effect => compile_keyword(Effect),
       encoder => compile_keyword(Encoder) };

compile_term(#{ <<"effect">> := EffectSpec, 
                <<"encoder">> := EncoderSpec }, Index) ->
    #{ effect => compile_term(EffectSpec, Index),
       encoder => compile_term(EncoderSpec, Index) };

compile_term(#{ <<"effect">> := Effect  }, _) when is_binary(Effect) ->
    #{ effect => compile_keyword(Effect) };

compile_term(#{ <<"effect">> := Spec }, Index) when is_map(Spec) ->
    #{ effect => compile_term(Spec, Index) };

compile_term(#{ <<"encoder">> := Enc }, _) when is_binary(Enc) ->
    #{ encoder => compile_keyword(Enc) };

compile_term(#{ <<"encoder">> := Spec }, Index) when is_map(Spec) ->
    #{ encoder => compile_term(Spec, Index) };

compile_term(#{ <<"init">> := Init }, Index) ->
    compile_init(Init, Index);

compile_term(#{ <<"update">> := Update }, Index) ->
    compile_updates(Update, Index);

compile_term(#{ <<"views">> := Views }, Index) ->
    compile_views(Views, Index);

compile_term(#{ <<"effects">> := Effects }, Index) ->
    compile_effects(Effects, Index);

compile_term(#{ <<"either">> := Specs }, Index) when is_list(Specs) ->
    #{ type => either,
       options => lists:map(fun(S) ->
                                    compile_option(S, Index)
                            end, Specs) };


compile_term(#{ <<"spec">> := Spec,
                <<"to">> := To }, Index) when is_binary(To) ->
    #{ to => cmkit:to_atom(To),
       spec => compile_term(Spec, Index) 
     };

compile_term(#{ <<"connection">> := ConnSpec,
                <<"status">> := Status }, Index) ->
    #{ connection => compile_term(ConnSpec, Index),
       status => cmkit:to_atom(Status)
     };

compile_term(#{ <<"data">> := <<"any">> }, _) ->
    #{ type => data };

compile_term(#{ <<"any">> := <<"data">> }, _) ->
    #{ type => data };

compile_term(#{ <<"file">> := <<"any">> }, _) ->
    #{ type => file };

compile_term(#{ <<"any">> := <<"date">>,
                <<"format">> := Format }, _) ->
    #{ type => date,
       format => cmkit:to_atom(Format) };

compile_term(#{ <<"date">> := <<"any">>,
                <<"format">> := Format }, _) ->
    #{ type => date,
       format => cmkit:to_atom(Format) };

compile_term(#{ <<"now">> := <<"microseconds">> }, _Index) ->

    #{ type => now,
       resolution => micros };

compile_term(#{ <<"now">> := <<"milliseconds">> }, _Index) ->

    #{ type => now,
       resolution => millis };

compile_term(#{ <<"calendar">> := <<"now">> }, _Index) ->

    #{ type => utc,
       amount => 0, 
       factor => 0,
       tense => past };


compile_term(#{ <<"calendar">> := #{ 
                    <<"days">> := #{ <<"ago">> := Days }}}, Index) -> 

    #{ type => utc,
       amount => compile_term(Days, Index),
       factor => 3600*24,
       tense => past };

compile_term(#{ <<"calendar">> := #{ 
                    <<"days">> := #{ <<"in">> := Days }}}, Index) -> 

    #{ type => utc,
       amount => compile_term(Days, Index),
       factor => 3600*24,
       tense  => future };

compile_term(#{ <<"encrypt">> := #{ <<"method">> := Method,
                                    <<"key">> := Key,
                                    <<"value">> := Value }}, Index) -> 
    #{ type => encrypt,
       spec => #{
         method => compile_keyword(Method),
         key => compile_term(Key, Index),
         value => compile_term(Value, Index) } };

compile_term(#{ <<"base64">> := Spec,
                <<"as">> := As }, Index) ->

    #{ type => base64,
       as => cmkit:to_atom(As),
       spec => compile_term(Spec, Index) };

compile_term(#{ <<"base64">> := Spec }, Index) ->
    #{ type => base64,
       spec => compile_term(Spec, Index) };

compile_term(#{ <<"json">> := Spec }, Index) -> 
    #{ type => json,
       spec => compile_term(Spec, Index) };

compile_term(#{ <<"as">> := As,
                <<"file">> := Spec }, Index) when is_map(Spec) ->
    #{ type => file,
       as => cmkit:to_atom(As),
       spec => compile_term(Spec, Index) 
     };

compile_term(#{ <<"file">> := #{ <<"path">> := P,
                                 <<"data">> := D }}, Index) -> 
    #{ type => file,
       spec => #{ path => compile_term(P, Index),
                  data => compile_term(D, Index)}};

compile_term(#{ <<"file">> := Spec }, Index) when is_map(Spec) ->
    #{ type => file,
       spec => compile_term(Spec, Index) 
     };

compile_term(#{ <<"asset">> := Spec, 
                <<"as">> := As }, Index) ->

    #{ type => asset,
       as => cmkit:to_atom(As),
       spec => compile_term(Spec, Index) 
     };

compile_term(#{ <<"asset">> := Spec}, Index) ->

    #{ type => asset,
       spec => compile_term(Spec, Index) 
     };

compile_term(#{ <<"any">> := <<"file">> }, _) ->
    #{ type => file };

compile_term(#{ <<"at">> := Spec,
                <<"contents">> := DataSpec }, Index) ->
    #{ type => path,
       location => compile_term(Spec, Index),
       state => present,
       contents => compile_term(DataSpec, Index)
     };

compile_term(#{ <<"at">> := Spec }, Index) ->
    #{ type => path,
       location => compile_term(Spec, Index) 
     };

compile_term(#{ <<"data">> := Spec,
                <<"as">> := As }, Index) ->
    #{ type => data,
       spec => compile_term(Spec, Index),
       as => cmkit:to_atom(As) };

compile_term(#{ <<"data">> := Spec }, Index) ->
    maps:merge(#{ type => data},
               compile_term(Spec, Index));

compile_term(#{ <<"rm">> := Spec }, Index) -> 
    #{ type => rm,
       spec => compile_term(Spec, Index) };

compile_term(#{ <<"template">> := #{ <<"name">> := Name,
                                     <<"params">> := ParamsSpec,
                                     <<"dest">> := Dest }}, Index) ->
    #{ type => template,
       name => cmkit:to_atom(Name),
       params => compile_term(ParamsSpec, Index),
       dest => compile_term(Dest, Index) };

compile_term(#{<<"empty">> := <<"object">> }, _) ->
    #{ type => object, size => 0 };

compile_term(#{<<"empty">> := <<"list">> }, _) ->
    #{ type => list, size => 0 };

compile_term(#{<<"empty">> := _}, _) ->
    #{ type => empty };

compile_term(#{ <<"config">> := Spec}, Index) when is_map(Spec) ->
    #{ type => config,
       spec => compile_term(Spec, Index)
     };

compile_term(#{ <<"config">> := Key} = Spec, Index) when is_binary(Key) ->
    compile_term(Spec#{ <<"config">> := #{ <<"key">> => Key }}, Index);

compile_term(#{ <<"maybe">> := Spec }, Index) ->
    #{ maybe => compile_term(Spec, Index) };


compile_term(#{ <<"alias">> := Target,
                <<"as" >> := As }, Index) ->
    #{ type => alias,
       target => compile_term(Target, Index),
       as => compile_term(As, Index) };

compile_term(#{ <<"os">> := #{ <<"name">> := Var,
                               <<"default">> := Default }}, Index) ->
    #{ type => os,
       name => compile_term(Var, Index),
       default => compile_term(Default, Index) };

compile_term(#{ <<"os">> := Var,
                <<"default">> := Default }, Index) ->
    #{ type => os,
       name => compile_term(Var, Index),
       default => compile_term(Default, Index) };

compile_term(#{ <<"os">> := Var }, Index) ->
    #{ type => os,
       name => compile_term(Var, Index) };

compile_term(#{ <<"object">> := Object}, Index) ->
    compile_object(Object, Index);

compile_term(#{ <<"without_keys">> := Keys }, Index) when is_list(Keys) ->
    #{ type => without_keys,
       spec => compile_terms(Keys, Index) };

compile_term(#{ <<"with_keys">> := Keys }, Index) when is_list(Keys) ->
    #{ type => with_keys,
       spec => compile_terms(Keys, Index) };

compile_term(#{ <<"entries">> := Spec }, Index) ->
    #{ type => entries,
       spec => compile_term(Spec, Index)
     };

compile_term(#{ <<"view">> := View }, Index) ->
    #{ type => view ,
       spec => compile_view(View, Index)
     };

compile_term(#{ <<"list">> := <<"empty">>}, _) ->
    #{ type => list, size => 0 };

compile_term(#{ <<"list">> := <<"any">>}, _) ->
    #{ type => list };

compile_term(#{ <<"any">> := <<"list">>}, _) ->
    #{ type => list };

compile_term(#{ <<"list">> := #{ <<"with">> := With }}, Index) -> 
    #{ type => list,
       with => compile_term(With, Index) };

compile_term(#{ <<"list">> := #{ <<"without">> := With }}, Index) -> 
    #{ type => list,
       without => compile_term(With, Index) };

compile_term(#{ <<"by_replacing">> := #{ <<"items">> := Items,
                                      <<"with">> := With }}, Index) ->
    #{ type => by_replacing, 
       items => compile_term(Items, Index),
       with => compile_term(With, Index) };

compile_term(#{ <<"by_replacing">> := Spec}, Index) ->
    #{ type => by_replacing, 
       spec => compile_term(Spec, Index) };

compile_term(#{ <<"by_appending">> := Spec }, Index) ->
    #{ type => by_appending, 
       spec => compile_term(Spec, Index) };

compile_term(#{ <<"by_removing">> := Spec }, Index) ->
    #{ type => by_removing, 
       spec => compile_term(Spec, Index) };

compile_term(#{ <<"size_of">> := Spec }, Index) -> 
    #{ type => size_of,
       spec => compile_term(Spec, Index) }; 

compile_term(#{ <<"list">> := Items }, Index) when is_list(Items) ->
    #{ type => list,
       value => lists:map(fun(I) -> 
                             compile_term(I, Index)     
                          end, Items) };

compile_term(#{ <<"list">> := #{ <<"size">> := Size } = Spec }, _) when is_map(Spec) andalso map_size(Spec) =:= 1 ->
    #{ type => list,
       size => Size
     };

compile_term(#{ <<"list">> := #{ <<"size">> := Size } = Spec }, Index) when is_map(Spec) ->
    #{ type => list,
       size => Size,
       spec => compile_term(Spec, Index)
     };

compile_term(#{ <<"list">> := Spec }, Index) when is_map(Spec) ->
    #{ type => list,
       spec => compile_term(Spec, Index)
     };

compile_term(#{ <<"merged_list">> := Specs }, Index) when is_list(Specs) ->
    #{ type => merged_list,
       spec => compile_terms(Specs, Index)
     };

compile_term(#{ <<"first">> := Spec }, Index) when is_map(Spec) ->
    #{ type => first,
       spec => compile_term(Spec, Index)
     };


compile_term(#{ <<"merge">> := Specs }, Index) when is_list(Specs) -> 
    #{ type => merge,
       spec => compile_terms(Specs, Index)
     };

compile_term(#{ <<"flattened">> := Specs }, Index) when is_list(Specs) -> 
    #{ type => flattened,
       spec => compile_terms(Specs, Index)
     };

compile_term(#{ <<"map">> := #{ <<"value">> := From,
                                <<"options">> := Options }}, Index) ->
    #{ type => map,
       spec => #{ 
         value => compile_term(From, Index),
         options => compile_options(Options, Index)
        }
     };

compile_term(#{ <<"hash">> := Spec }, Index) -> 
    #{ type => hash,
       spec => compile_term(Spec, Index) };

compile_term(#{ <<"spec">> := Spec }, Index) ->
    compile_spec(Spec, Index); 

compile_term(#{ <<"expression">> := Spec }, Index) ->
    #{ type => expression, 
       spec => compile_term(Spec, Index) }; 

compile_term(#{ <<"encoded">> := Spec }, Index) ->
    #{ type => encoded, 
       spec => compile_term(Spec, Index) }; 

%compile_term(#{ <<"type">> := Type}, _) ->
%    compile_keyword(Type);

compile_term(#{ <<"keyword">> := Keyword }, _) when is_binary(Keyword) ->
    #{ type => keyword,
       value => cmkit:to_atom(Keyword) };

compile_term(#{ <<"keyword">> := Keyword }, _) when is_atom(Keyword) ->
    #{ type => keyword,
       value => Keyword };

compile_term(#{ <<"keyword">> := Spec }, Index) when is_map(Spec) ->
    #{ type => keyword,
       spec => compile_term(Spec, Index) };


compile_term(#{ <<"number">> := Num }, _) when is_number(Num) ->
    #{ type => number, value => Num };

compile_term(#{ <<"number">> := <<"any">> }, _) ->
    #{ type => number };

compile_term(#{ <<"number">> := Spec }, Index) when is_map(Spec) ->
    #{ type => number, spec => compile_term(Spec, Index) };

compile_term(#{ <<"at_least">> := Spec }, Index) ->
    #{ type => greater_than,
       spec => compile_term(Spec, Index) };

compile_term(#{ <<"literal">> := V }, _) when is_binary(V) or is_number(V) or is_atom(V) ->
    #{ value => V };

compile_term(#{ <<"literal">> := Spec }, Index) when is_list(Spec) or is_map(Spec) ->
    #{ literal => compile_term(Spec, Index) };

compile_term(#{ <<"object">> := <<"any">> }, _) ->
    #{ type => object };

compile_term(#{ <<"object">> := <<"empty">> }, _) ->
    #{ type => object, size => 0 };

compile_term(#{ <<"empty">> := <<"object">> }, _) ->
    #{ type => object, size => 0 };

compile_term(#{ <<"any">> := <<"object">> }, _) ->
    #{ type => object };

compile_term(#{ <<"text">> := <<"any">> }, _) ->
    #{ type => text };

compile_term(#{ <<"non_empty">> := <<"text">> }, _) ->
    #{ type => non_empty, spec => #{ type => text } };

compile_term(#{ <<"any">> := <<"text">> }, _) ->
    #{ type => text };

compile_term(#{ <<"email">> := <<"any">> }, _) ->
    #{ type => email };

compile_term(#{ <<"any">> := <<"email">> }, _) ->
    #{ type => email };

compile_term(#{ <<"any">> := <<"keyword">> }, _) ->
    #{ type => keyword };

compile_term(#{ <<"keyword">> := <<"any">> }, _) ->
    #{ type => keyword };

compile_term(#{ <<"any">> := <<"number">> }, _) ->
    #{ type => number };

compile_term(#{ <<"number">> := <<"any">> }, _) ->
    #{ type => number };

compile_term(#{ <<"any">> := <<"boolean">> }, _) ->
    #{ type => boolean };

compile_term(#{ <<"boolean">> := <<"any">> }, _) ->
    #{ type => boolean };

compile_term(#{ <<"regexp">> := Regex }, Index) ->
    #{ type => regexp,
       value => compile_term(Regex, Index) };

compile_term(#{ <<"text">> := Spec }, Index) when is_map(Spec) -> 
    #{ type => text,
       spec => compile_term(Spec, Index) };

compile_term(#{ <<"text">> := Spec }, Index)-> 
    maps:merge(#{ type => text},
               compile_term(Spec, Index));

compile_term(#{ <<"format">> := #{ <<"pattern">> := Pattern,
                                   <<"params">> := Params }}, Index) when is_list(Params) -> 
    #{ type => format,
       pattern => compile_term(Pattern, Index),
       params => compile_terms(Params, Index) };

compile_term(#{ <<"format">> := Pattern,
                <<"params">> := Params }, Index) when is_list(Params) -> 
    #{ type => format,
       pattern => compile_term(Pattern, Index),
       params => compile_terms(Params, Index) };

compile_term(#{ <<"format">> := #{ <<"pattern">> := Pattern,
                                   <<"params">> := Params }}, Index) when is_map(Params) -> 
    #{ type => format,
       pattern => compile_term(Pattern, Index),
       params => compile_term(Params, Index) };

compile_term(#{ <<"format">> := #{ <<"pattern">> := FormatSpec,
                                   <<"date">> := DateSpec }}, Index) -> 

    #{ type => format,
       pattern => compile_term(FormatSpec, Index),
       date => compile_term(DateSpec, Index) };

compile_term(#{ <<"format">> := FormatSpec,
                <<"date">> := DateSpec }, Index) -> 

    #{ type => format,
       pattern => compile_term(FormatSpec, Index),
       date => compile_term(DateSpec, Index) };


compile_term(#{ <<"replace">> := #{ <<"in">> := SourceSpec,
                                    <<"text">> := SearchSpec,
                                    <<"with">> := ReplaceSpec }}, Index) ->
    #{ type => replace,
       source => compile_term(SourceSpec, Index),
       text => compile_term(SearchSpec, Index),
       with => compile_term(ReplaceSpec, Index) };

compile_term(#{ <<"lowercase">> := Spec}, Index) ->
    #{ type => lowercase,
       spec => compile_term(Spec, Index) };

compile_term(#{ <<"uppercase">> := Spec}, Index) ->
    #{ type => uppercase,
       spec => compile_term(Spec, Index) };


compile_term(#{ <<"files">> := Spec }, Index) -> 
    #{ type => files,
       spec => compile_term(Spec, Index) 
     };

compile_term(<<"from_data">>, _) -> from_data;
compile_term(#{ <<"from_data">> := _ }, _) -> from_data;

compile_term(#{ <<"item">> := Num,
                <<"in">> := In }, Index) when is_map(In) ->

    #{ item => Num,
       in => compile_term(In, Index)
     };

compile_term(#{ <<"item">> := Num,
                <<"in">> := In }, _) when is_binary(In) ->

    #{ item => Num,
       in => compile_keyword(In)
     };

compile_term(#{ <<"item">> := Num }, _) when is_number(Num) ->
    #{ item => Num };

compile_term(#{ <<"i18n">> := KeySpec0} = Spec, Index) ->
    KeySpec = case KeySpec0 of 
                  #{ <<"key">> := _ } ->
                      KeySpec0;
                  Path when is_binary(Path) ->
                      #{ <<"key">> => Path }
              end,

    LangSpec = case maps:get(<<"lang">>, Spec, undef) of 
                   undef ->
                       #{ key => lang, default => en };
                   L ->
                       compile_term(L, Index)
               end,
    
    In = compile_term(KeySpec, Index),
    InPath = to_key_path(In),
    Default = case maps:get(<<"default">>, Spec, undef) of 
                  undef ->
                      #{ type => format,
                         pattern => <<"??~s.~s??">>,
                         params => [ InPath, LangSpec ] };
                  DefaultSpec ->
                      compile_term(DefaultSpec, Index)
              end,

    #{ key => LangSpec,
       in => In,
        default => Default };


compile_term(#{ <<"key">> := Key, 
                <<"in">> := In } = Spec, Index) when is_binary(Key) andalso is_binary(In) -> 
    
    with_default(Spec, #{ key => compile_keyword(Key),
                          in => compile_keyword(In)
                        }, Index);

compile_term(#{ <<"key">> := Key, 
                <<"in">> := In } = Spec, Index) when is_binary(Key) -> 
    
    with_default(Spec, #{ key => compile_keyword(Key),
                          in => compile_term(In, Index)
                        }, Index);

compile_term(#{ <<"key">> := Key, 
                <<"in">> := In } = Spec,  Index) when is_binary(In) -> 

    with_default(Spec, #{ key => compile_term(Key, Index),
                          in => compile_keyword(In)
                        }, Index);

compile_term(#{ <<"key">> := Key, 
                <<"in">> := In } = Spec, Index) -> 
    
    with_default(Spec, #{ key => compile_term(Key, Index),
                           in => compile_term(In, Index)
                         }, Index);

compile_term(#{ <<"key">> := Key } = Spec, Index) ->
    Compiled = case is_key_path(Key) of 
                  false ->
                        #{ key => compile_term(Key, Index) };
                  true ->
                      compile_key_path(Key)
              end,
    with_default(Spec, Compiled, Index);

compile_term(#{ <<"one_of">> := Specs }, Index) when is_list(Specs) ->
    #{ one_of => lists:map(fun(S) ->
                              compile_term(S, Index)     
                           end, Specs) }; 

compile_term(#{ <<"all">> := Specs }, Index) when is_list(Specs) ->
    #{ all => lists:map(fun(S) ->
                              compile_term(S, Index)     
                           end, Specs) }; 


compile_term(#{ <<"loop">> := From,
                <<"context">> := Context,
                <<"with">> := View }, Index) when is_map(From) ->

    ItemViewSpec = case is_binary(View) of 
                       true -> cmkit:to_atom(View);
                       false -> compile_term(View, Index)
                   end,

    #{ loop => compile_term(From, Index),
       with => ItemViewSpec,
       context => compile_term(Context, Index) };

compile_term(#{ <<"loop">> := From,
                <<"context">> := _,
                <<"with">> := _ } = Spec, Index) when is_binary(From) ->

    compile_term(Spec#{ <<"loop">> => #{ <<"key">> => From }}, Index);

compile_term(#{ <<"loop">> := _} = Spec, Index)  ->

    compile_term(Spec#{ <<"context">> => #{} }, Index);

compile_term(#{ <<"are_set">> := Specs }, Index) when is_list(Specs) ->
    #{ type => are_set,
       spec => lists:map(fun(S) -> 
                                 compile_term(S, Index)
                         end, Specs)};

compile_term(#{ <<"set">> := Spec }, Index) ->
    #{ type => set,
       spec => compile_term(Spec, Index)
     };

compile_term(#{ <<"is_set">> := Spec }, Index) ->
    #{ type => is_set,
       spec => compile_term(Spec, Index)
     };

compile_term(#{ <<"not">> := Spec }, Index) ->
    #{ type => 'not',
       spec => compile_term(Spec, Index)
     };

compile_term(#{ <<"equal">> := Specs }, Index) when is_list(Specs) ->
    #{ type => equal,
       spec => lists:map(fun(S) ->
                            compile_term(S, Index)     
                         end, Specs)};

compile_term(#{ <<"eq">> := Specs }, Index) when is_list(Specs) ->
    #{ type => equal,
       spec => lists:map(fun(S) ->
                            compile_term(S, Index)     
                         end, Specs)};

compile_term(#{ <<"other_than">> := Spec }, Index) ->
    #{ type => other_than,
       spec => compile_term(Spec, Index) };

compile_term(#{ <<"gt">> := Specs }, Index) when is_list(Specs) ->
    #{ type => greater_than,
       spec => lists:map(fun(S) ->
                            compile_term(S, Index)     
                         end, Specs)};

compile_term(#{ <<"sum">> := Specs }, Index) when is_list(Specs) ->
    #{ type => sum,
       spec => lists:map(fun(S) ->
                            compile_term(S, Index)     
                         end, Specs)};

compile_term(#{ <<"and">> := Specs }, Index) when is_list(Specs) ->
    #{ type => 'and',
       spec => lists:map(fun(S) ->
                            compile_term(S, Index)     
                         end, Specs)};

compile_term(#{ <<"or">> := Specs }, Index) when is_list(Specs) ->
    #{ type => 'or',
       spec => lists:map(fun(S) ->
                            compile_term(S, Index)     
                         end, Specs)};

compile_term(#{ <<"ratio">> := #{ <<"num">> := Num,
                                  <<"den">> := Den }}, Index) ->
    #{ type => ratio,
       num => compile_term(Num, Index),
       den => compile_term(Den, Index)
     };

compile_term(#{ <<"percentage">> := #{ <<"num">> := Num,
                                       <<"den">> := Den }}, Index) ->
    #{ type => percentage,
       num => compile_term(Num, Index),
       den => compile_term(Den, Index)
     };

compile_term(#{ <<"member">> := Spec }, Index) -> 

    #{ type => member,
       spec => compile_term(Spec, Index)
     };

compile_term(#{ <<"present">> := Spec }, Index) ->
    #{ type => present,
       spec => compile_term(Spec, Index) };

compile_term(#{ <<"value">> := ValueSpec,
                <<"of">> := CollectionSpec
              }, Index) ->

    #{ value => compile_term(ValueSpec, Index),
       in => compile_term(CollectionSpec, Index)
     };

compile_term(#{ <<"all">> := Conds }, Index) ->
    #{ type => all,
       spec => lists:map(fun(C) ->
                            compile_term(C, Index)     
                         end, Conds) 
     };

compile_term(#{ <<"connect">> := Spec,
                <<"as">> := As } = Spec0, Index) ->
    Expr = #{ type => connect,
              as => compile_term(As, Index),
              spec => compile_term(Spec, Index) },

    Expr2 = case maps:get(<<"protocol">>, Spec0, undef) of 
                undef -> 
                    Expr;
                ProtocolSpec -> 
                    Expr#{ protocol => compile_term(ProtocolSpec, Index) }
            end,

    Expr2;


compile_term(#{ <<"connect">> := Spec }, Index) ->
    #{ type => connect,
       spec => compile_term(Spec, Index) };

compile_term(#{ <<"probe">> := Spec }, Index) ->

    #{ type => probe,
       spec => compile_term(Spec, Index)
     };

compile_term(#{ <<"disconnect">> := Spec }, Index) ->

    #{ type => disconnect,
       spec => compile_term(Spec, Index)
     };

compile_term(#{ <<"send">> := 
                #{ <<"to">> := ConnSpec,
                   <<"spec">> := Spec }}, Index) ->
    #{ type => send,
       spec => #{ to => compile_term(ConnSpec, Index),
                  spec => compile_term(Spec, Index) }};

compile_term(#{ <<"send">> := Spec,
                <<"to">> := ConnSpec }, Index ) ->

    #{ type => send,
       spec => #{ to => compile_term(ConnSpec, Index),
                  spec => compile_term(Spec, Index) }};

compile_term(#{ <<"send">> := Spec }, Index) ->

    #{ type => send,
       spec => compile_term(Spec, Index)
     };


compile_term(#{ <<"receive">> := 
                #{ <<"from">> := From,
                   <<"spec">> := Spec,
                   <<"as">> := As }}, Index) ->
    #{ type => recv,
       from => compile_term(From, Index),
       spec => compile_term(Spec, Index),
       as => compile_term(As, Index)
     };

compile_term(#{ <<"receive">> := Spec,
                <<"from">> := From,
                <<"as">> := Remember}, Index) ->
    
    #{ type => recv,
       from => compile_term(From, Index),
       spec => compile_term(Spec, Index),
       as => compile_term(Remember, Index)
     };

compile_term(#{ <<"receive">> := 
                #{ <<"from">> := From,
                   <<"spec">> := Spec,
                   <<"remember">> := Remember }}, Index) ->
    #{ type => recv,
       from => compile_term(From, Index),
       spec => compile_term(Spec, Index),
       as => compile_object(Remember, Index)
     };

compile_term(#{ <<"receive">> := Spec,
                <<"from">> := From,
                <<"remember">> := Remember}, Index) ->
    
    #{ type => recv,
       from => compile_term(From, Index),
       spec => compile_term(Spec, Index),
       as => compile_object(Remember, Index)
     };

compile_term(#{ <<"receive">> := 
                #{ <<"from">> := From,
                   <<"spec">> := Spec }}, Index) ->

    #{ type => recv,
       from => compile_term(From, Index),
       spec => compile_term(Spec, Index),
       as => latest 
     };

compile_term(#{ <<"receive">> := Spec,
                <<"from">> := From }, Index) ->
    
    #{ type => recv,
       from => compile_term(From, Index),
       spec => compile_term(Spec, Index),
       as => latest
     };



compile_term(#{ <<"expect">> := Spec }, Index) ->
    #{ type => expect,
       spec => compile_term(Spec, Index)
     };

compile_term(#{ <<"parallel">> := #{ 
                    <<"count">> := Count,
                    <<"spec">> := Spec }}, Index) ->
    #{ type => parallel,
       count => compile_term(Count, Index),
       spec => compile_term(Spec, Index)
     };

compile_term(#{ <<"ref">> := Ref }, _) when is_binary(Ref) ->
    #{ ref => Ref };

compile_term(#{ <<"request">> := Spec,
                <<"as">> := As }, Index) ->
    #{ type => request,
       as => compile_term(As, Index),
       spec => compile_term(Spec, Index) 
     };

compile_term(#{ <<"request">> := Spec }, Index) ->
    #{ type => request,
       spec => compile_term(Spec, Index) 
     };

compile_term(#{ <<"response">> := Spec }, Index) ->
    #{ type => response,
       spec => compile_term(Spec, Index) 
     };


compile_term(#{ <<"split">> := Term,
                <<"using">> := Separator }, Index) ->
    #{ type => split,
       spec => compile_term(Term, Index),
       separator => compile_term(Separator, Index) };


compile_term(#{ <<"length">> := Term }, Index) ->
    #{ type => length,
       spec => compile_term(Term, Index) };


compile_term(#{ <<"head">> := Term }, Index) ->
    #{ type => head,
       spec => compile_term(Term, Index) };

compile_term(#{ <<"tail">> := Term }, Index) ->
    #{ type => tail,
       spec => compile_term(Term, Index) };

compile_term(#{ <<"join">> := Term,
                <<"using">> := Separator }, Index) ->

    #{ type => join,
       spec => compile_term(Term, Index),
       separator => compile_term(Separator, Index) };

compile_term(#{ <<"join">> := #{ 
                    <<"terms">> := Terms 
                   }
              }, Index) ->
    #{ type => join,
       separator => <<"">>,
       spec => compile_terms(Terms, Index) };

compile_term(#{ <<"join">> := Terms}, Index) when is_list(Terms) ->  
    #{ type => join,
       seperator => <<"">>,
       spec  => compile_terms(Terms, Index) };


compile_term(#{ <<"url">> := Url,
                <<"method">> := Method } = Spec, Index) ->

    Expr = #{ type => http,
              url => compile_term(Url, Index),
              method => cmkit:to_atom(Method)
            },

    Expr2 = case maps:get(<<"headers">>, Spec, undef) of 
                undef -> Expr;
                HeadersSpec -> 
                    Expr#{ headers => compile_term(HeadersSpec, Index) }
            end,

    Expr3 = case maps:get(<<"body">>, Spec, undef) of 
                undef -> Expr2;
                BodySpec -> 
                    Expr2#{ body => compile_term(BodySpec, Index) }
            end,
    Expr4 = case maps:get(<<"query">>, Spec, undef) of 
                undef -> Expr3;
                QuerySpec -> 
                    Expr3#{ query => compile_term(QuerySpec, Index) }
            end,
    with_debug(Spec, Expr4, Index);

compile_term(#{ <<"url">> := _}=Spec, Index) ->
    compile_term(Spec#{ method => <<"get">> }, Index);
    
compile_term(#{ <<"host">> := Host,
                <<"port">> := Port,
                <<"transport">> := Transport,
                <<"path">> := Path } = Spec, Index) ->

    Expr = #{ host => compile_term(Host, Index),
              port => compile_term(Port, Index),
              transport => compile_term(Transport, Index),
              path => compile_term(Path, Index) },

    Expr2 = case maps:get(<<"query">>, Spec, undef) of 
                undef ->
                    Expr;
                QuerySpec -> 
                    Expr#{ query => compile_term(QuerySpec, Index) }
            end,
    #{ type => url,
       spec => Expr2 };


compile_term(#{ <<"url_from">> := Spec}, Index) ->

    #{ type => url,
       spec => compile_term(Spec, Index) };


compile_term(#{ <<"multipart">> := #{ <<"files">> := FilesSpec } }, Index) ->
    #{ type => multipart,
       files => compile_term(FilesSpec, Index) };


compile_term(#{ <<"http">> := Spec } = S0, Index) ->
    
    Debug = maps:get(<<"debug">>, S0, <<"false">>),
    #{ type => exec,
       spec => compile_term(Spec#{ <<"debug">> => Debug }, Index) };

compile_term(#{ <<"procedure">> := Name,
                <<"params">> := Params }, Index) ->

    #{ type => procedure,
       name => cmkit:to_atom(Name),
       params => compile_term(Params, Index) };

compile_term(#{ <<"basic-auth">> := Spec }, Index) ->
    #{ type => basic_auth,
       spec => compile_term(Spec, Index) };

compile_term(#{ <<"task">> := Task }, _) -> 
    #{ type => task,
       name => compile_keyword(Task) };

compile_term(#{ <<"shell">> := 
                #{ <<"chwd">> := Chwd,
                   <<"cmd">> := Cmd }}, Index) ->
    #{ type => shell,
       chwd => compile_term(Chwd, Index),
       cmd => compile_term(Cmd, Index) };


compile_term(#{ <<"kube">> := Spec}, Index) ->
    #{ type => kube,
       spec => compile_kube_spec(Spec, Index) };

compile_term(#{ <<"slack">> := #{ <<"settings">> := SettingsSpec,
                                  <<"severity">> := SeveritySpec,
                                  <<"subject">> := SubjectSpec,
                                  <<"body">> := BodySpec }}, Index) ->
    #{ type => slack,
       spec => #{ settings => compile_term(SettingsSpec, Index),
                  severity => compile_term(SeveritySpec, Index),
                  subject => compile_term(SubjectSpec, Index),
                  body => compile_term(BodySpec, Index) }};


compile_term(#{ <<"slack">> := #{ <<"enabled">> := EnabledSpec,
                                  <<"token">> := TokenSpec,
                                  <<"channel">> := ChannelSpec,
                                  <<"severity">> := SeveritySpec,
                                  <<"subject">> := SubjectSpec,
                                  <<"body">> := BodySpec }}, Index) ->
    #{ type => slack,
       spec => #{ enabled => compile_term(EnabledSpec, Index),
                  token => compile_term(TokenSpec, Index),
                  channel => compile_term(ChannelSpec, Index),
                  severity => compile_term(SeveritySpec, Index),
                  subject => compile_term(SubjectSpec, Index),
                  body => compile_term(BodySpec, Index) }};

compile_term(#{ <<"git">> := <<"pull">>,
                <<"dir">> := Dir }, Index) ->
    
    #{ type => git,
       spec => #{ action => pull,
                  dir => compile_term(Dir, Index) }};
    
compile_term(#{ <<"git">> := #{ 
                    <<"credentials">> := CredsSpec,
                    <<"clone">> := #{ <<"repo">> := Repo,
                                      <<"branch">> := Branch,
                                      <<"dir">> := Dir }}}, Index) -> 
    #{ type => git,
       spec => #{ action => clone,
                  credentials => compile_term(CredsSpec, Index),
                  repo => compile_term(Repo, Index),
                  branch => cmkit:to_atom(Branch),
                  dir => compile_term(Dir, Index) }};

compile_term(#{ <<"git">> := #{ 
                    <<"credentials">> := CredsSpec,
                    <<"clone">> := #{ <<"repo">> := Repo,
                                      <<"dir">> := Dir }}}, Index) -> 
    #{ type => git,
       spec => #{ action => clone,
                  credentials => compile_term(CredsSpec, Index),
                  branch => master,
                  repo => compile_term(Repo, Index),
                  dir => compile_term(Dir, Index) }};

compile_term(#{ <<"git">> := #{ 
                    <<"as">> := As,
                    <<"credentials">> := CredsSpec,
                    <<"tag">> := #{ <<"repo">> := Repo,
                                    <<"dir">> := Dir,
                                    <<"prefix">> := Prefix,
                                    <<"increment">> := Increment } = Spec}}, Index) -> 
    GitSpec = #{ action => tag,
                 as => cmkit:to_atom(As),
                 credentials => compile_term(CredsSpec, Index),
                 repo => compile_term(Repo, Index),
                 dir => compile_term(Dir, Index),
                 prefix => compile_term(Prefix, Index),
                 increment => compile_term(Increment, Index) },

    GitSpec2  = case maps:get(<<"branch">>, Spec, undef) of 
                    undef -> GitSpec;
                    Br -> GitSpec#{ branch => cmkit:to_atom(Br) }
                end,

    GitSpec3 = case maps:get(<<"clone">>, Spec, undef) of 
                   undef -> GitSpec2#{ clone => true };
                   V -> 
                       GitSpec2#{ clone => cmkit:to_atom(V) }
               end,

    #{ type => git,
       spec => GitSpec3 };

compile_term(#{ <<"docker">> := #{ 
                    <<"credentials">> := CredsSpec,
                    <<"build">> := #{ <<"repo">> := Repo,
                                      <<"tag">> := Tag,
                                      <<"dir">> := Dir }}}, Index) -> 
    #{ type => docker,
       spec => #{ action => build,
                  credentials => compile_term(CredsSpec, Index),
                  repo => compile_term(Repo, Index),
                  tag => compile_term(Tag, Index),
                  dir => compile_term(Dir, Index) }};

compile_term(#{ <<"docker">> := #{ 
                    <<"credentials">> := CredsSpec,
                    <<"pull">> := #{ <<"repo">> := Repo,
                                      <<"tag">> := Tag  }}}, Index) -> 
    #{ type => docker,
       spec => #{ action => pull,
                  credentials => compile_term(CredsSpec, Index),
                  repo => compile_term(Repo, Index),
                  tag => compile_term(Tag, Index) }};

compile_term(#{ <<"test">> := #{ 
                    <<"name">> := Test,
                    <<"settings">> := Settings,
                    <<"opts">> := Opts }}, Index) -> 
    #{ type => test,
       spec => #{ name => cmkit:to_atom(Test),
                  settings => cmkit:to_atom(Settings),
                  opts => compile_term(Opts, Index) }};

compile_term(#{ <<"wait">> := #{
                    <<"sleep">> := Sleep,
                    <<"retries">> := Retries,
                    <<"condition">> := Condition }}, Index) ->
    #{ type => wait,
       spec => #{ sleep => Sleep,
                  retries => Retries,
                  condition => compile_term(Condition, Index) }};

compile_term(#{ <<"wait">> := #{ 
                    <<"seconds">> := Secs }}, _) -> 
    #{ type => wait,
       spec => #{
         sleep => Secs * 1000 }};

compile_term(#{ <<"wait">> := Secs }, _) -> 
    #{ type => wait,
       spec => #{
         sleep => Secs * 1000 }};

compile_term(#{ <<"match">> := #{
                    <<"value">> := ValueSpec,
                    <<"with">> := DecoderSpec } = MatchSpec}, Index) ->

    Expr = #{ value => compile_term(ValueSpec, Index),
              decoder => compile_term(DecoderSpec, Index)},

    Expr2 = case maps:get(<<"remember">>, MatchSpec, undef) of
                undef -> Expr;
                RememberSpec -> 
                    Expr#{ map => compile_term(RememberSpec, Index) }
            end,

    #{ type => match, spec => Expr2 };

compile_term(#{ <<"match">> := ValueSpec,
                <<"with">> := DecoderSpec } = Spec, Index) ->

    Spec2 = maps:without([<<"match">>, <<"with">>], Spec),
    MatchSpec = Spec2#{ <<"value">> => ValueSpec,
                        <<"with">> => DecoderSpec },
    compile_term(#{ <<"match">> => MatchSpec}, Index);

compile_term(#{ <<"find">> := TargetSpec,
                <<"in">> := SourceSpec }, Index) -> 

    #{ type => find,
       items => compile_term(SourceSpec, Index),
       target => compile_term(TargetSpec, Index) };


compile_term(#{ <<"sort">> := ItemsSpec,
                <<"by">> := PropSpec,
                <<"mode">> := ModeSpec }, Index) ->

    #{ type => sort,
       items => compile_term(ItemsSpec, Index),
       by => compile_term(PropSpec, Index),
       mode => compile_term(ModeSpec, Index) };

compile_term(#{ <<"encode">> := SourceSpec,
                <<"with">> := EncoderSpec} = Spec, Index) when is_map(EncoderSpec) ->
    
    #{ type => encode,
       source => compile_term(SourceSpec, Index),
       as => maybe_compile_as(Spec, Index),
       dest => compile_term(EncoderSpec, Index) };

compile_term(#{ <<"encode">> := _,
                <<"with">> := With } = Spec, Index) when is_binary(With) ->
    compile_term(Spec#{ <<"with">> => #{ <<"encoder">> => With }}, Index);

compile_term(#{ <<"iterate">> := SourceSpec,
                <<"with">> := DestSpec } = Spec, Index) ->
    
    FilterSpec = case maps:get(<<"filter">>, Spec, none) of 
                none ->
                    none;
                S1 ->
                    compile_term(S1, Index)
             end,

    #{ type => iterate,
       source => compile_term(SourceSpec, Index),
       filter => FilterSpec,
       as => maybe_compile_as(Spec, Index),
       dest => compile_term(DestSpec, Index) };

compile_term(#{ <<"filter">> := SourceSpec,
                <<"with">> := FilterSpec }, Index) ->
    
    #{ type => filter,
       source => compile_term(SourceSpec, Index),
       filter => compile_term(FilterSpec, Index) };

compile_term(#{ <<"error">> := Spec }, Index) ->
    #{ type => error,
       spec => compile_term(Spec, Index) };

compile_term(#{ <<"attempt">> := Spec,
                <<"onerror">> := OnError }, Index) -> 

    #{ type => attempt,
       spec  => compile_term(Spec, Index),
       onerror => compile_term(OnError, Index)
     };

compile_term(#{ <<"attempt">> := #{ <<"spec">> := Spec,
                                    <<"onerror">> := OnError } }, Index) -> 

    #{ type => attempt,
       spec  => compile_term(Spec, Index),
       onerror => compile_term(OnError, Index)
     };

compile_term(#{ <<"attempt">> := Spec }, Index) -> 
    
    #{ type => attempt,
       spec  => compile_term(Spec, Index),
       onerror => compile_term(#{ type => keyword,
                                  value => ok }, Index)
     };


compile_term(#{ <<"queue">> := NameSpec,
                <<"notify">> := JobSpec,
                <<"info">> := InfoSpec }, Index) ->
    #{ type => queue,
       name => compile_term(NameSpec, Index),
       notify => compile_term(JobSpec, Index),
       info => compile_term(InfoSpec, Index) };

compile_term(#{ <<"queue">> := NameSpec,
                <<"finish">> := JobSpec }, Index) ->
    #{ type => queue,
       name => compile_term(NameSpec, Index),
       finish => compile_term(JobSpec, Index) };

compile_term(#{ <<"erlang">> := #{ <<"mod">> := Mod,
                                   <<"fun">> := Fun } = Spec}, Index) -> 

    Args = maps:get(<<"args">>, Spec, []),

    #{ type => erlang,
       mod => compile_keyword(Mod),
       function => compile_keyword(Fun),
       args => compile_term(Args, Index) };

compile_term(#{ <<"thumbnail">> := #{ <<"url">> := U,
                                      <<"basename">> := B,
                                      <<"sizes">> := S }}, Index) -> 

    #{ type => thumbnail,
       url => compile_term(U, Index),
       basename => compile_term(B, Index),
       sizes => compile_terms(S, Index) };

compile_term(#{ <<"s3">> := #{ <<"access">> := Access,
                               <<"secret">> := Secret,
                               <<"bucket">> := Bucket,
                               <<"key">> := Key,
                               <<"data">> := Data }}, Index) -> 

    #{ type => s3,
       spec => #{ access => compile_term(Access, Index),
                  secret => compile_term(Secret, Index),
                  bucket => compile_term(Bucket, Index),
                  key => compile_term(Key, Index),
                  data => compile_term(Data, Index) }};

compile_term(#{ <<"db">> := #{ <<"bucket">> := B,
                               <<"type">> := T,
                               <<"id">> := Id,
                               <<"value">> := Value }}, Index) -> 
    #{ type => db,
       spec => #{ bucket => compile_term(B, Index),
                  type => compile_term(T, Index),
                  id => compile_term(Id, Index),
                  value => compile_term(Value, Index) }};


compile_term(#{ <<"queue">> := #{ <<"name">> := Name,
                                  <<"finish">> := Id}}, Index) ->

    #{ type => queue,
       spec => #{ action => finish,
                  name => compile_keyword(Name),
                  id => compile_term(Id, Index) }};

compile_term(#{ <<"with">> := Spec}, Index) -> 
    #{ with => compile_object(Spec, Index) };

compile_term(#{ <<"without">> := Spec}, Index) -> 
    #{ without => compile_term(Spec, Index) };

compile_term(Num, _) when is_number(Num) ->
    #{ type => number, value => Num };

compile_term(Text, _) when is_binary(Text) -> 

    #{ type => text, spec => Text };

compile_term(#{ <<"sequence">> := #{ <<"from">> := From,
                                     <<"to">> := To }}, Index) ->
    #{ type => sequence,
       from => compile_term(From, Index),
       to => compile_term(To, Index) };

compile_term(#{ <<"pipe">> := Specs,
                <<"as">> := As }, Index) ->

    #{ type => pipe,
       specs => compile_terms(Specs, Index),
       as => compile_keyword(As) };

compile_term(Term, Index) when is_map(Term) ->
    #{ type => object,
       spec => maps:fold(fun(K, V, Out) ->
                                 K2 = cmkit:to_atom(K),
                                 V2 = compile_term(V, Index),
                                 Out#{ K2 => V2 }
                         end, #{}, Term) };

compile_term(true, _) -> 
    #{ type => keyword,
       value => true };

compile_term(<<"yes">>, _) -> 
    #{ type => keyword,
       value => true };

compile_term(false, _) -> 
    #{ type => keyword,
       value => false };

compile_term(<<"no">>, _) -> 
    #{ type => keyword,
       value => false };

compile_term(#{ <<"lat">> := Lat, <<"lon">> := Lon }, _) ->
    #{ lat => Lat, 
       lon => Lon };


compile_term(#{}=Map, _) when map_size(Map) == 0 ->
    #{ type => object };

compile_term(null, _) -> 
    #{ type => object };

compile_term(Items, Index) when is_list(Items) ->
    #{ type => list,
       value => lists:map( fun(I) -> 
                                   compile_term(I, Index)
                           end, Items) };

compile_term([], _) -> 
    #{ type => list, value => [] };

compile_term(Spec, _) ->
    cmkit:danger({cmconfig, compile, term_not_supported, Spec}),
    #{ type => unknown, spec => Spec }.


compile_as(As, Index) when is_binary(As) or is_atom(As) ->
    compile_term(#{ <<"keyword">> => As }, Index);

compile_as(As, Index) when is_map(As) ->
    compile_term(As, Index).

maybe_compile_as(Spec, Index) when is_map(Spec) ->
    case maps:get(<<"as">>, Spec, none) of
        none ->
            none;
        AsSpec ->
            compile_as(AsSpec, Index)
    end.



compile_kube_spec(#{ <<"kind">> := Kind,
                     <<"namespace">> := NsSpec,
                     <<"state">> := StateSpec,
                     <<"server">> := ApiServerSpec }=Spec, Index) ->

    Expr = #{ state => compile_term(StateSpec, Index),
              namespace => compile_term(NsSpec, Index),
              resource => cmkit:to_atom(Kind),
              server => compile_term(ApiServerSpec, Index)
            },

    Expr2 = case maps:get(<<"name">>, Spec, undef) of 
                undef -> 
                    Expr;
                NameSpec ->
                    Expr#{ name => compile_term(NameSpec, Index) }
            end,

    Expr3 = case maps:get(<<"props">>, Spec, undef) of 
                undef ->
                    Expr2;
                PropsSpec ->
                    Expr2#{ props => compile_term(PropsSpec, Index) }
            end,

    Expr3.

compile_object(<<"any">>, _) -> 
    #{ type => object };

compile_object(<<"empty">>, _) -> 
    #{ type => object, size => 0 };

compile_object(null, _) ->
    #{ type => object };

compile_object(Map, Index) when is_map(Map) ->
    #{ type => object,
       spec => compile_object(maps:keys(Map), Map, Index, #{}) };

compile_object(Other, _) ->
    cmkit:warning({cmconfig, compile_object, Other, not_supported}),
    #{ type => object }.

compile_object([], _, _, Out) -> Out;
compile_object([K|Rem], Map, Index, Out) ->
    compile_object(Rem, Map, Index, Out#{ 
                               compile_keyword(K) => compile_term(maps:get(K, Map), Index)
                              }).

compile_keyword(K) -> cmkit:to_atom(K).

compile_decoders(Decs, Index) when is_map(Decs) ->
    compile_decoders(maps:keys(Decs), Decs, Index, []);

compile_decoders(_, _) -> [].


compile_decoders([], _, _, Out) -> sort_decoders(Out);
compile_decoders([K|Rem], Decs, Index, Out) ->
    Msg = compile_keyword(K),
    Dec = maps:get(K, Decs),
    Spec = compile_term(Dec, Index),
    compile_decoders(Rem, Decs, Index, [#{ msg => Msg,
                                    priority => compile_priority(Dec),
                                    spec => Spec}|Out]). 

compile_priority(#{ <<"priority">> := P }) ->
    compile_keyword(P);

compile_priority(_) ->
    compile_keyword(normal).


compile_options(Spec, Index) when is_map(Spec) ->
    compile_options(maps:keys(Spec), Spec, Index, []).

compile_options([], _, _, Out) -> Out;
compile_options([K|Rem], Spec, Index, Out) ->
    compile_options(Rem, Spec, Index, [#{ source => compile_term(K, Index),
                                   target => compile_term(maps:get(K, Spec), Index)
                                 }|Out]).


sort_decoders(Decs) -> lists:sort(fun compare_priorities/2, Decs).

compare_priorities(#{ priority := _ }, #{ priority := lowest }) -> true;
compare_priorities(#{ priority := lowest }, #{ priority := _ }) -> false;
compare_priorities(#{ priority := _ }, #{ priority := _ }) -> true.

compile_encoders(Encs, Index) when is_map(Encs) ->
    compile_encoders(maps:keys(Encs), Encs, Index, #{});

compile_encoders(Other, Index) ->
    cmkit:warning({cmconfig, invalid_encoders, Other}),
    compile_encoders(#{}, Index).

compile_encoders([], _, _, Out) -> Out;
compile_encoders([K|Rem], Encs, Index, Out) ->
    Name = compile_keyword(K),
    Enc = compile_term(maps:get(K, Encs), Index),
    compile_encoders(Rem, Encs, Index, Out#{ Name => Enc}). 


compile_updates(Updates, Index) when is_map(Updates) -> 
    compile_updates(maps:keys(Updates), Updates, Index, #{});

compile_updates(Other, Index) -> 
    cmkit:warning({cmconfig, Other, no_updates}),
    compile_updates(#{}, Index).

compile_updates([], _, _, Out) -> Out;
compile_updates([K|Rem], Updates, Index, Out) ->
    Name = compile_keyword(K),
    Init = compile_init(maps:get(K, Updates), Index),
    compile_updates(Rem, Updates, Index, Out#{ Name => Init }).

compile_update_spec(Spec, Index) when is_map(Spec) -> 
    Condition = case maps:get(<<"when">>, Spec, undef) of 
                    undef -> #{ type => true };
                    S -> compile_term(S, Index)
                end,
    
    Cmds = case maps:get(<<"cmds">>, Spec, []) of 
               L when is_list(L) -> 
                   compile_terms(L, Index);
               Other ->
                   compile_term(Other, Index)
           end,

    #{ condition => Condition, 
       model => compile_model(maps:get(<<"model">>, Spec, #{}), Index),
       cmds => Cmds 
     }.

compile_init(Spec, Index) when is_map(Spec) ->
    compile_init([Spec], Index);

compile_init(Specs, Index) when is_list(Specs) -> 
    lists:map(fun(S) ->
                      compile_update_spec(S, Index)
              end, Specs).

compile_views(Views, Index) ->
    compile_views(maps:keys(Views), Views, Index, #{}).

compile_views([], _, _, Out) -> Out;
compile_views([K|Rem], Views, Index, Out) ->
    Name = compile_keyword(K),
    View = compile_view(maps:get(K, Views), Index),
    compile_views(Rem, Views, Index, Out#{ Name => View }).


compile_view(#{ <<"view">> := View,
                <<"params">> := Params,
                <<"when">> := When }, Index) ->
    
    
    #{ view => compile_term(View, Index),
       params => compile_term(Params, Index),
       condition => compile_term(When, Index) };

compile_view(#{ <<"view">> := View,
                <<"when">> := When }, Index) ->

    #{ view => compile_term(View, Index),
       condition => compile_term(When, Index) };


compile_view(#{ <<"view">> := View,
                <<"params">> := Params }, Index) ->

    #{ view => compile_term(View, Index),
       params  => compile_term(Params, Index) };

compile_view(#{ <<"view">> := View }, Index) ->

    #{ view => compile_term(View, Index),
       params  => #{} };

compile_view(#{ <<"tag">> := Tag,
                <<"attrs">> := Attrs,
                <<"children">> := Children }, Index) when is_map(Children)->
    #{ tag => Tag,
       attrs => compile_term(Attrs, Index),
       children => compile_term(Children, Index) 
     };

compile_view(#{ <<"tag">> := Tag,
                <<"attrs">> := Attrs,
                <<"children">> := Children }, Index) when is_list(Children)->
    #{ tag => Tag,
       attrs => compile_term(Attrs, Index),
       children => lists:map(fun(C) ->
                                compile_view(C, Index)     
                             end, Children) };

compile_view(#{ <<"tag">> := _ ,
                <<"children">> := _ }=View, Index) ->
    compile_view(View#{ <<"attrs">> => #{}}, Index);

compile_view(#{ <<"tag">> := _ ,
                <<"attrs">> := _ }=View, Index) ->
    compile_view(View#{ <<"children">> => []}, Index);

compile_view(#{ <<"tag">> := _ }=View, Index) ->
    compile_view(View#{ 
                   <<"attrs">> => #{},
                   <<"children">> => []}, Index);

compile_view(#{ <<"text">> := Text}, _) when is_binary(Text) ->
    #{ text => #{ literal => Text }};

compile_view(#{ <<"text">> := Spec}, Index) ->
    #{ text => compile_term(Spec, Index) };

compile_view(#{ <<"iterate">> := From,
                <<"using">> := ItemView }, Index) ->
    #{ iterate => compile_term(From, Index), 
       using => compile_keyword(ItemView) };

compile_view(#{ <<"json">> := Spec,
                <<"indent">> := Indent }, Index) ->
    #{ json => compile_term(Spec, Index),
       indent => compile_term(Indent, Index) };

compile_view(#{ <<"json">> := _} = Spec, Index) ->
    compile_view(Spec#{ <<"indent">> => 2 }, Index);

compile_view(#{ <<"code">> := #{ <<"source">> := Source,
                                 <<"lang">> := Lang }}, Index) -> 
    #{ code => #{ lang => compile_term(Lang, Index),
                 source => compile_term(Source, Index) }};

compile_view(#{ <<"prettify">> := Spec }, _) -> 
    #{ type => prettify,
       spec => Spec };

compile_view(#{ <<"timestamp">> :=  #{ <<"format">> := Format,
                                       <<"value">> := Value }}, Index) ->

    #{ timestamp => #{ format => compile_term(Format, Index),
                       value => compile_term(Value, Index) }};

compile_view(#{ <<"date">> :=  #{ <<"format">> := Format,
                                  <<"value">> := Value }}, Index) ->

    #{ date  => #{ 
         format => compile_term(Format, Index),
         value => compile_term(Value, Index) }};


compile_view(#{ <<"map">> := #{ <<"id">> := Id,
                                <<"style">> := Style,
                                <<"zoom">> := Zoom,
                                <<"center">> := Center,
                                <<"markers">> := Markers }}, Index) ->

    #{ map => #{ id => compile_term(Id, Index),
                 style => cmkit:to_atom(Style),
                 zoom => Zoom,
                 center => compile_term(Center, Index),
                 markers => compile_terms(Markers, Index) }};

compile_view(#{ <<"markdown">> := Spec }, Index) -> 
    #{ markdown => compile_term(Spec, Index)};


compile_view(#{ <<"loop">> := _ ,
                <<"with">> := _ } = Spec, Index) ->
    compile_term(Spec, Index);


compile_view(#{ <<"chart">> := Type,
                <<"labels">> := Labels,
                <<"data">> := Data } = Spec, Index) ->

    Expr0 = #{ type => compile_term(Type, Index),
                   labels => compile_term(Labels, Index),
                   data => compile_term(Data, Index) },
    Expr = case maps:get(<<"low">>, Spec, undef) of 
               undef -> 
                   Expr0#{ low => 0 };
               LowSpec ->
                   Expr0#{ low => compile_term(LowSpec, Index)}
           end,

    #{ chart => Expr };

compile_view(Spec, _) ->
    cmkit:danger({cmconfig, compile, view_spec_not_supported, Spec}),
    #{ view => not_supported,
       spec => Spec }.

%compile_view_attrs(Attrs, Index) when is_map(Attrs) ->
%    maps:fold(fun(K, V, Attrs2) ->
%                      Attrs2#{ compile_keyword(K) => compile_term(V, Index) }
%              end, #{}, Attrs). 


compile_model(Map, Index) -> compile_term(Map, Index).

resolve_modules(Names, All) ->
    lists:map(fun(Name) ->
                      resolve_module(cmkit:to_atom(Name), All)
              end, Names).

resolve_module(Name, All) -> 
    case maps:get(Name, All, undef) of 
        undef -> 
            cmkit:warning({cmconfig, no_such_module, Name, maps:keys(All)}),
            #{ status => unknown,
               name => compile_keyword(Name) };
        Mod -> 
            Mod
    end.

compile_effects(Effects, Index) ->
    compile_effects(maps:keys(Effects), Effects, Index, #{}).

compile_effects([], _, _, Out) -> Out;
compile_effects([K|Rem], Effects, Index, Out) ->
    Name = compile_keyword(K),
    compile_effects(Rem, Effects, Index, Out#{ Name => compile_effect(Name, maps:get(K, Effects), Index) }).

compile_effect(Name, #{ <<"type">> := Type, <<"settings">> := Settings}, Index) ->
    #{ type => effect,
       name => Name,
       class => Type,
       settings => compile_object(maps:keys(Settings), Settings, Index, #{}) 
     };

compile_effect(Name, #{ <<"type">> := _ }=Effect, Index) -> compile_effect(Name, Effect#{ <<"settings">> => #{}}, Index).


%%with_default(#{ in := In, key := _} = Spec, Default) ->
%%    Spec#{ default => Default, in => with_default(In, Default)};
%%
%%with_default(#{ key := _} = Spec, Default) ->
%%    Spec#{ default => Default }.



with_default(#{ <<"default">> := Default }, Compiled, Index) ->
    Compiled#{ default => compile_term(Default, Index) };

with_default(_, Compiled, _) -> Compiled.

with_debug(#{ <<"debug">> := Debug}, Compiled, Index) ->
    Compiled#{ debug => compile_term(Debug, Index) };

with_debug(_, Compiled, _) -> Compiled#{ debug => false }.
    
