(function() {
    const config = (window.elementary || {})
    const state = {}
    
    function tc(fun) {
        const t1 = new Date();
        const r = fun();
        const t2 = new Date();
        return { millis: t2.getMilliseconds() - t1.getMilliseconds(),
                 res: r };
    }

    function error(spec, data, reason) {
        return {err: {spec, data, reason}};
    }
    function fmt(pattern, args) {
        var argNum = 0;
        return pattern.replace(/~a/gi, function(match) {
            var curArgNum, prop = null;
            curArgNum = argNum;
            argNum++;
            var result = curArgNum >= args.length ? "" : prop ? args[curArgNum][prop] || "" : args[curArgNum];
            return result;
        });
    };

    function encodeEntries(spec, data) {
        function _(keys, v) {
            if (!keys.length) return {value: v};
            var k = keys.shift();
            const { err, value } = encode(spec[k], data);
            if (err) return error(spec[k], data, err);
            v[k] = value;
            return _(keys, v);
        }
        return _(Object.keys(spec), {});
    }

    function encodeKey(spec, data) {
        if (!data) return error(spec, data, "no_data");
        switch(typeof(spec)) {
            case 'string':
                if (!data.hasOwnProperty(spec)) return error(spec, data, "missing_key");
                return { value: data[spec]};
            case 'object':
                if (spec.in) {
                    var {err, value} = encodeKey(spec.in, data);
                    if (err) return error(spec, data, err);
                    return encodeKey({ key: spec.key }, value)
                } else {
                    switch (typeof(spec.key)) {
                        case 'object' :
                            var {err, value} = encode(spec.key, data);
                            if (err) return error(spec, data, err);
                            return encodeKey({ key: value }, data);
                        case 'string' :
                            if (!data.hasOwnProperty(spec.key)) return error(spec, data, "missing_key");
                            return { value: data[spec.key]};
                        default:
                            return error(spec, data, "key_spec_not_supported");
                    }
                }
            default:
                return error(spec, data, "key_spec_not_supported");
        }
    }

    function encodeList(items, data) {
        function _(items, v) {
            if (!items.length) return { value: v };
            var item = items.shift();
            const { err, value } = encode(item, data);
            if (err) return error(item, data, err);
            v.push(value);
            return _(items, v);
        }
        return _(items.slice(0), []);
    }

    function encodeFormat(spec, data) {
        const { pattern, params } = spec.format;
        const { err, value } = encodeList(params, data);
        return err ? error(spec, data, err) : {value: fmt( pattern, value)};
    }

    function encodeMaybe(spec, data) {
        const { err, value } = encode(spec.maybe, data);
        return {value};
    }

    function encodeEqual(spec, data) {
        function _(rem, v) {
            if (!rem.length) return { value: true };
            const s = rem.shift();
            const { err, value } = encode(s, data);
            if (err) return error(spec, data, err);
            return (v && value != v) ? { value: false } : _(rem, value);
        }
        return _(spec.equal.slice(0));
    }

    function encodeIsSet(spec, data) {
        var {err, value} = encode(spec.spec, data);
        if (err) return error(spec, data, err);
        return value ? { value: true } : { value: false };
    }
    
    function encodeNot(spec, data) {
        var {err, value} = encode(spec.spec, data);
        if (err) return error(spec, data, err);
        if (!typeof(value) === 'boolean') return error(spec, data, {
            value: value,
            reason: "not_a_boolean"
        });
        return { value: !value };
    }

    function encodeEither(spec, data) {
        function _(i) {
            if (i == spec.either.length) return error(spec, data, "no_condition_matched")
            var s = spec.either[i];
            var { err, value } = encode(s.when, data);
            if (err) return error(spec, data, err);
            if (!value) return _(i+1);
            var { err, value } = encode(s.then, data);
            if (err) return error(spec, data, err);
            return { value };
        }
        return _(0);
    }

    function encodeUsingEncoder(spec, data) {
        var enc = state.app.encoders[spec.encoder];
        if (!enc) return error(spec, data, "no_such_encoder");
        return encode(enc, data);
    }

    function encodeTimestamp(spec, data) {
        if (spec.timestamp.format) {
            var {err, value} = encode(spec.timestamp.format, data);
            if (err) return error(spec, data, err);
            var pattern = value;
            var {err, value} = encode(spec.timestamp.value, data);
            if (err) return error(spec, data, err);

            switch(pattern) {
                case "human":
                    return { value: moment(value).fromNow() };
                default:
                    return { value: moment(value).format(pattern) };

            }
        }
        return error(spec, data, "unsupported_timestamp_spec");
    }

    function encodeText(spec, data) {
        var {err, value} = encode(spec.text, data);
        if (err) return error(spec, data, err);
        return { value: ''+ value };
    }

    function encodePercent(spec, data) {
        var {err, value} = encode(spec.percent.num, data);
        if (err) return error(spec, data, err);
        var num = value;
        var {err, value} = encode(spec.percent.den, data);
        if (err) return error(spec, data, err);
        var den = value;
        if (!den) return { value: 0 }; 
        return {value : Math.floor(num/den)*100};
        
    }


    function encode(spec, data) {
        switch(typeof(spec)) {
            case "object":
                if (Array.isArray(spec)) return encodeList(spec, data);
                if (spec.object) return encodeEntries(spec.object, data);
                if (spec.key) return encodeKey(spec, data);
                if (spec.format) return encodeFormat(spec, data);
                if (spec.maybe) return encodeMaybe(spec, data);
                if (spec.equal) return encodeEqual(spec, data);
                if (spec.either) return encodeEither(spec, data);
                if (spec.encoder) return encodeUsingEncoder(spec, data);
                if (spec.timestamp) return encodeTimestamp(spec, data);
                if (spec.text) return encodeText(spec, data);
                if (spec.percent) return encodePercent(spec, data);
                if (spec.is_set) return encodeIsSet(spec, data);
                if (spec.not) return encodeNot(spec, data);
                if (!Object.keys(spec).length) return {value: {}};
                return error(spec, data, 'encoder_not_supported');
            default: 
                return { value: spec };
        }
    }

    function decodeObject(spec, data, ctx) {
        if (!data || typeof(data) != 'object') return error(spec, data, "no_match");
        function _(keys, out) {
            if (!keys.length) return { decoded: out};
            var k = keys.shift();
            var spec2 = spec.object[k];
            const {err, decoded} = decode(spec2, data[k], ctx);
            if (err) return error(spec, data, err);
            out[k] = decoded;
            return _(keys, out);
        }
        return _(Object.keys(spec.object), {});
    }


    function decodeAny(spec, data, ctx) {
        switch (spec.any) {
            case "text":
                if (typeof(data) === 'string') return {decoded: data};
            case "number":
                if (typeof(data) === 'number') return {decoded: data};
            case "boolean":
                if (typeof(data) === 'boolean') return {decoded: data};
            case "list": 
                if (Array.isArray(data)) return {decoded: data};
            case "object":
                if (typeof(data) === 'object') return {decoded: data};
            default: 
                return error(spec, data, "no_match");
        }
    }

    function decodeListItems(spec, data, ctx) {
        var out = [];
        for (var i=0; i<data.length; i++) {
            var item = data[i];
            var { err, decoded } = decode(spec, item, ctx);
            if (err) return error(spec, data, err);
            out.push(decoded);
        }
        return { decoded: out};
    }

    function decodeList(spec, data, ctx) {
        if (!Array.isArray(data)) return error(spec, data, "no_match");
        if (Array.isArray(spec.list)) {
            return error(spec, data, "decoder_not_supported");
        } else return decodeListItems(spec.list, data, ctx);
    }
    
    function decodeOne(spec, data, ctx) {
        function _(i) {
            if (i == spec.one_of.length) return error(spec, data, "no_match")
            var s = spec.one_of[i];
            var { err, decoded } = decode(s, data, ctx);
            if (err) return _(i+1);
            return { decoded };
        }
        return _(0);
    } 
    
    
    function decodeJson(spec, data, ctx) {
        try {
            return { value: JSON.parse(spec.json)};
        } catch (e) {
            return { err: { json: spec.json, error: e} };
        }
    }
    
    function decodeSize(spec, data) {
        var {err, value} = encode(spec.size, data);
        if (err) return error(spec, data, err);
        switch (typeof(data)) {
            case 'object':
                if (Array.isArray(data) && data.length == value) return {decoded:data}; 
                if (Object.keys(data).length == value) return {decoded: data};
            case 'string':
                if (data && data.length == value) return {decoded: data};
        }
        return error(spec, data, "no_match");
    };

    function decode(spec, data, ctx) {
        switch(typeof(spec)) {
            case "object":
                if (Array.isArray(spec)) return error(spec, data, "decoder_not_supported");
                if (spec.object) return decodeObject(spec, data, ctx);
                if (spec.any) return decodeAny(spec, data, ctx);
                if (spec.list) return decodeList(spec, data, ctx);
                if (spec.one_of) return decodeOne(spec, data, ctx);
                if (spec.json) return decodeJson(spec, data, ctx);
                if (spec.size) return decodeSize(spec, data, ctx);
            default :
                return (spec === data) ? { decoded: data } : error(spec, data, "no_match");
        }
    }

    function tryDecoders(data, decoders) {
        if (!data.effect) return error(null, data, "no_effect_in_data");
        var decs = decoders[data.effect];
        if (!decs || !decs.length) return error(null, data, "no_decoders");
        for (var i=0; i<decs.length; i++) {
            var d = decs[i];
            var spec = d.spec;
            const {err, decoded} = decode(spec, data, state.model)
            if (!err && decoded) return {decoded: {msg: d.msg, data: decoded}};
        }

        return error(null, data, "all_decoders_failed");
    }

    function selectUpdate(msg, update, data, model) {
        var clauses = update[msg];
        if (!clauses || !clauses.length) return error(msg, data, "no_update_implemented");
        for (var i=0; i<clauses.length; i++) {
            var c = clauses[i];
            const { err, value } = encode(c.condition, model);
            if (err) return error(c.condition, model, err);
            if (value) return {spec: c};
        }
        return error(clauses, data, "all_conditions_failed");
    }


    function app(next) {
        fetch('/js/app.js')
            .then((mod) => {
                return mod.json();
            })
            .then(next)
            .catch((err) => {
                console.error("app error", err);
            });
    };

    function effects(app, next) {
        const names = Object.keys(app.effects);
        Promise.all(names.map(function(n) {
            return import('/js/' + app.effects[n].class  + '.js');
        })).then((mods) => {
            const out = {};
            for (var i=0; i<names.length; i++) {
                const n = names[i];
                const settings = Object.assign({}, state.app.settings, app.effects[n].settings);
                const send = mods[i].default(n, settings, {
                    encode,
                    decode,
                    update,
                    tc
                });
                if (send instanceof Function) {
                    out[n] = send;
                } else {
                    console.warn('effect ' + n + ' of type ' + app.effects[n].class
                        + ' is not returning a send function', send);
                }
            }
            next(out);
        });
    }

    function applyCmds(encoders, effects, cmds, m2) {
        cmds.forEach((cmd) => {
            const { effect, encoder } = cmd;
            const eff = effects[effect];
            if (!eff) {
                console.error("No such effect", cmd);
                return;
            }

            var enc = null;
            if (encoder) {
                enc = encoders[encoder];
                if (!enc) {
                    console.error("No such encoder", cmd);
                    return;
                }
            }

            setTimeout(() => {   
                eff(encoders, enc, Object.assign({}, m2));
            }, 0);
        });
    }

    function updateModel(spec, data) {
        if (!spec) return;
        var {err, value} = encode(spec, data);
        if (err) return err;
        Object.assign(state.model, value);
    }

    function log(msg, data) {
        if (state.app.settings.debug) console.log(msg, data);
    }

    function update(ev) {
        const { encoders, effects, decoders, update } = state.app;
        const t0 = new Date();
        var {err, decoded } = tryDecoders(ev, decoders);
        if (err) {
            console.error("Decode error", err);
            return;
        }
        const { msg, data } = decoded;
        log("[core] decoded", decoded);
        const t1= new Date();
        var {err, spec} = selectUpdate(msg, update, data, state.model);
        if (err) {
            console.error("Update error", err);
            return;
        } 
        
        log("[core] update spec", spec);
        var err = updateModel(spec.model, data);
        if (err) {
            console.error("Update error", err);
            return;
        }
        const t2 = new Date();
        log("[core] new model", state.model);
        applyCmds(encoders, state.effects, spec.cmds, state.model);
        const t3 = new Date();
        if (state.app.settings.telemetry) {
            console.log("[core]"
                + "[decode " + (t1.getMilliseconds() - t0.getMilliseconds()) + "ms]"
                + "[update " + (t2.getMilliseconds() - t1.getMilliseconds()) + "ms]"
                + "[cmds " + (t3.getMilliseconds() - t2.getMilliseconds()) + "ms]");
        }
    }
    
    function init(app) {
        const { init } = app;
        const { model, cmds } = init;

        const t0 = new Date();
        const { err, value } = encode(model, {});
        if (err) {
            console.error("(init) cannot encode model", err);
        } else {
            state.model = value;
            const t1 = new Date();
            applyCmds(app.encoders, state.effects, cmds, state.model);
            const t2 = new Date();
            if (state.app.settings.telemetry) {
                console.log("[core]"
                    + "[init " + (t1.getMilliseconds() - t0.getMilliseconds()) + "ms]"
                    + "[cmds " + (t2.getMilliseconds() - t1.getMilliseconds()) + "ms]");
            }
        }
    }

    function indexedDecoders(decs, index) {
        var index = {};
        for (var k in decs) {
            if (decs.hasOwnProperty(k)) {
                var d = decs[k];
                var eff = d.object && d.object.effect ? d.object.effect : '_other';
                if (!index[eff]) index[eff]=[];
                index[eff].push({ msg: k, spec: d});
            }
        }
        return index;
    }

    function compiledApp(app) {
        app.decoders = indexedDecoders(app.decoders);
        app.settings = app.settings || {};
        return app;
    }
    
    app(function(app) {
        state.app = compiledApp(app);
        if (state.app.settings.debug) console.log(app);
        effects(app, (effs) => {
            state.effects = effs;
            init(app);
        });
    });

})();