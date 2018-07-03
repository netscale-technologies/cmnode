-module(cmnode_effect_terminate).
-export([ effect_info/0,
          effect_apply/2
        ]).

effect_info() -> terminate.

effect_apply(_, SessionId) ->

    cmkit:log({cmeffect, terminate, SessionId}),
    cmcore:terminate(SessionId).