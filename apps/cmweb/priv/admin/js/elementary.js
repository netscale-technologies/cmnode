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

    function typeOf(data) {
        if (!data) return "undefined";
        var t = typeof(data);
        if (t === 'object') {
            return (Array.isArray(data)) ? "list" : "object";
        } else return (t === 'string') ? "text" : t;
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


    function encodeObject(spec, data, ctx, out) {
        for (var k in spec.object) {
            if (spec.object.hasOwnProperty(k)) {
                const { err, value } = encode(spec.object[k], data, (ctx || {})[k]);
                if (err) return error(spec.object[k], data, err);
                out[k] = value;
            }
        }
        return { value: out };
    }

    function encodeNewObject(spec, data, ctx) {
        return encodeObject(spec, data, ctx, {});
    }
    
    function encodeKey(spec, data, ctx) {
        if (!data) return error(spec, data, "no_data");
        switch(typeof(spec)) {
            case 'string':
                if (!data.hasOwnProperty(spec)) return error(spec, data, "missing_key");
                return { value: data[spec]};
            case 'object':
                if (spec.in) {
                    var {err, value} = encodeKey(spec.in, data, ctx);
                    if (err) return error(spec, data, err);
                    var inCtx = value;
                    switch (typeof(spec.key)) {
                        case 'object':
                            var {err, value} = encode(spec.key, data, ctx);
                            if (err) return error(spec, data, err);
                            var keySpec = value;
                            return encodeKey({ key: keySpec}, inCtx, ctx);
                        case 'string':
                            if (!inCtx.hasOwnProperty(spec.key)) return error(spec, inCtx, "missing_key");
                            return { value: inCtx[spec.key]};
                        default:
                            return error(spec, data, "key_spec_not_supported");

                    }
                } else {
                    switch (typeof(spec.key)) {
                        case 'object' :
                            var {err, value} = encode(spec.key, data, ctx);
                            if (err) return error(spec, data, err);
                            return encodeKey({ key: value }, data, ctx);
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

    function encodeList(items, data, ctx) {
        function _(items, v) {
            if (!items.length) return { value: v };
            var item = items.shift();
            const { err, value } = encode(item, data, ctx);
            if (err) return error(item, data, err);
            v.push(value);
            return _(items, v);
        }
        return _(items.slice(0), []);
    }
    
    function encodeByAppending(spec, data, ctx) {
        if (!ctx) return error(spec, ctx, "no_data");
        switch(typeof(ctx)) {
            case 'object':
                if (Array.isArray(ctx)) {
                    var {err, value} = encode(spec.by_appending, data, ctx);
                    if (err) return error(spec, data, err);
                    ctx.push(value);
                    return { value: ctx };
                }
        }

        return error(spec, ctx, "by_adding spec not supported");
    }
    
    function encodeByRemoving(spec, data, ctx) {
        if (!ctx) return error(spec, ctx, "no_data");
        switch(typeof(ctx)) {
            case 'object':
                if (Array.isArray(ctx)) {
                    for (var i=0; i<ctx.length; i++) {
                        var item = ctx[i];
                        var {err, decoded} = decode(spec.by_removing, item, data);
                        if (!err) {
                            ctx.splice(i, 1);
                        }
                    }
                    return { value: ctx};
                }
        }
        return error(spec, ctx, "by_removing spec not supported");
    }

    function encodeByReplacing(spec, data, ctx) {
        if (!ctx) return error(spec, ctx, "no_data");
        switch(typeof(ctx)) {
            case 'object':
                if (Array.isArray(ctx)) {
                    var itemSpec = spec.by_replacing.items;
                    var encodeSpec = spec.by_replacing.with;
                    var out = [];
                    for (var i=0; i<ctx.length; i++) {
                        var item = ctx[i];
                        var {err, decoded} = decode(itemSpec, item, data);
                        if (err) {
                            out[i] = item;
                        } else {
                            var {err, value} = encode(encodeSpec, {item, data}, item);
                            if (err) return error(spec, data, err);
                            out[i] = value;
                        }
                    }
                    return {value: out};
                }

                return encodeObject(spec.by_replacing, data, ctx, ctx);
        }
        
        return error(spec, ctx, "by_replacing spec not supported");
    }

    function encodeFormat(spec, data, ctx) {
        const { pattern, params } = spec.format;
        const { err, value } = encodeList(params, data, ctx);
        return err ? error(spec, data, err) : {value: fmt( pattern, value)};
    }

    function encodeMaybe(spec, data, ctx) {
        const { err, value } = encode(spec.maybe, data, ctx);
        return {value};
    }

    function encodeEqual(spec, data, ctx) {
        if (!spec.equal.length) return {value: false};
        var {err, value}= encode(spec.equal[0], data, ctx);
        if (err) return error(spec, data, err);
        var expected = value;
        for (var i=1; i<spec.equal.length; i++) {
            var s = spec.equal[i];
            var { err, value}= encode(s, data, ctx);
            if (err) return error(spec, data, err);
            if (value != expected) return { value: false};
        }
        
        return {value: true};
    }
    
    function encodeAnd(spec, data, ctx) {
        if (!spec.and) return {value: false};
        for (var i=0; i<spec.and.length; i++) {
            var s = spec.and[i];
            var {err, value}= encode(s, data, ctx);
            if (err) return error(spec, data, err);
            if (!value) return {value: false}
        }
        return {value: true};
    }
    
    function encodeOr(spec, data, ctx) {
        if (!spec.or) return {value: false};
        for (var i=0; i<spec.or.length; i++) {
            var s = spec.or[i];
            var {err, value}= encode(s, data, ctx);
            if (err) return error(spec, data, err);
            if (value) return {value: true}
        }
        return {value: false};
    }

    function encodeIsSet(spec, data, ctx) {
        var {err, value} = encode(spec.is_set, data, ctx);
        if (err) return error(spec, data, err);
        var v = data[value];
        if (!v) return {value: false};
        switch (typeof(v)) {
            case 'string':
                return v.length ? { value: true }: {value: false};
        }
        return {value: true}
    }
    
    function encodeNot(spec, data, ctx) {
        var {err, value} = encode(spec.not, data, ctx);
        if (err) return error(spec, data, err);
        if (!typeof(value) === 'boolean') return error(spec, data, {
            value: value,
            reason: "not_a_boolean"
        });
        return { value: !value };
    }

    function encodeEither(spec, data, ctx) {
        function _(i) {
            if (i == spec.either.length) return error(spec, data, "no_condition_matched")
            var s = spec.either[i];
            var { err, value } = encode(s.when, data, ctx);
            if (err) return error(spec, data, err);
            if (!value) return _(i+1);
            var { err, value } = encode(s.then, data, ctx);
            if (err) return error(spec, data, err);
            return { value };
        }
        return _(0);
    }

    function encodeUsingEncoder(spec, data, ctx) {
        var enc = state.app.encoders[spec.encoder];
        if (!enc) return error(spec, data, "no_such_encoder");
        return encode(enc, data, ctx);
    }

    function encodeTimestamp(spec, data, ctx) {
        if (spec.timestamp.format) {
            var {err, value} = encode(spec.timestamp.format, data, ctx);
            if (err) return error(spec, data, err);
            var pattern = value;
            var {err, value} = encode(spec.timestamp.value, data, ctx);
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

    function encodeText(spec, data, ctx) {
        var {err, value} = encode(spec.text, data, ctx);
        if (err) return error(spec, data, err);
        return { value: new String(''+value) };
    }

    function encodePercent(spec, data, ctx) {
        var {err, value} = encode(spec.percent.num, data, ctx);
        if (err) return error(spec, data, err);
        var num = value;
        var {err, value} = encode(spec.percent.den, data, ctx);
        if (err) return error(spec, data, err);
        var den = value;
        if (!den) return { value: 0 }; 
        return {value : Math.floor(num/den)*100};
        
    }

    function encodeAny(spec, data, ctx) {
        if (spec.any === 'object' && typeof(data) === 'object' && !Array.isArray(data)) {
            return {value: data};
        }

        return error(spec, data, "any spec not supported");
    }
    
    function encodeExpression(spec, data, ctx) {
        return {value: spec.expression};
    }
    
    function encodeEncoded(spec, data, ctx) {
        var {err, value} = encode(spec.encoded, data, ctx);
        if (err) return error(spec, data, err);
        return encode(value, data, ctx);
    }

    function encodePrettify(spec, data, ctx) {
        var {err, value} = encode(spec.prettify, data, ctx);
        if (err) return error(spec, data, err);
        return {value: JSON.stringify(value, null, 2)};
    }

    function encodePercent(spec, data, ctx) {
        var {err, value} = encode(spec.percent.den, data, ctx);
        if (err) return error(spec, data, err);
        if (!value) return error(spec, data, "denominator is zero");
        var den = value;
        var {err, value} = encode(spec.percent.num, data, ctx);
        if (err) return error(spec, data, err);
        return {value: Math.round(100*value/den)};
    }

    function encodeSum(spec, data, ctx) {
        var {err, value} = encodeList(spec.sum, data, ctx);
        if (err) return error(spec, data, err);
        if (!value || !value.length) return {value: 0};
        var sum = 0;
        for (var i=0; i<value.length; i++) {
            var item = value[i];
            if (typeof(item) != 'number') return error(spec, item, "not_a_number");
            sum += item;
        }
        return {value: sum};
    }

    var sizeEncoders = {
        "undefined": (d) => { return 0},
        "list": (d) => { return d.length },
        "object": (d) => { return Object.keys(d).length },
        "string": (d) => { return d.length },
        "number": (d) => { return d.number },
        "boolean": (d) => { return 0 }
    }

    function encodeSizeOf(spec, data, ctx) {
        var {err, value} = encode(spec.size_of, data, ctx);
        if (err) return error(spec, data, err);
        var e = sizeEncoders[typeOf(value)];
        if (!e) return error(spec, value, "cannot_encode_size");
        var s = e(value);
        return {value: s};
    }

    function encode(spec, data, ctx) {
        switch(typeof(spec)) {
            case "object":
                if (Array.isArray(spec)) return encodeList(spec, data, ctx);
                if (spec.object) return encodeNewObject(spec, data, ctx);
                if (spec.by_appending) return encodeByAppending(spec, data, ctx);
                if (spec.by_replacing) return encodeByReplacing(spec, data, ctx);
                if (spec.by_removing) return encodeByRemoving(spec, data, ctx);
                if (spec.key) return encodeKey(spec, data, ctx);
                if (spec.format) return encodeFormat(spec, data, ctx);
                if (spec.maybe) return encodeMaybe(spec, data, ctx);
                if (spec.equal) return encodeEqual(spec, data, ctx);
                if (spec.either) return encodeEither(spec, data, ctx);
                if (spec.encoder) return encodeUsingEncoder(spec, data, ctx);
                if (spec.timestamp) return encodeTimestamp(spec, data, ctx);
                if (spec.text) return encodeText(spec, data, ctx);
                if (spec.percent) return encodePercent(spec, data, ctx);
                if (spec.is_set) return encodeIsSet(spec, data, ctx);
                if (spec.not) return encodeNot(spec, data, ctx);
                if (spec.and) return encodeAnd(spec, data, ctx);
                if (spec.or) return encodeOr(spec, data, ctx);
                if (spec.any) return encodeAny(spec, data, ctx);
                if (spec.expression) return encodeExpression(spec, data, ctx);
                if (spec.encoded) return encodeEncoded(spec, data, ctx);
                if (spec.prettify) return encodePrettify(spec, data, ctx);
                if (spec.percent) return encodePercent(spec, data, ctx);
                if (spec.sum) return encodeSum(spec, data, ctx);
                if (spec.size_of) return encodeSizeOf(spec, data, ctx);
                if (!Object.keys(spec).length) return {value: {}};
                console.warn("returning spec as default encoding value", spec);
                return { value: spec };
            case "string":
                return { value: spec };
            case "boolean":
                return { value: spec };
            case "number":
                return { value: spec };
            default:
                return error(spec, data, "encoder_not_supported");
        }
    }

    function objectValueDecoder(spec, ctx) {
        if (spec.key) {
            return encode(spec, ctx);
        } else return {value: spec};
    }

    function decodeObject(spec, data, ctx) {
        if (!data || typeof(data) != 'object') return error(spec, data, "no_match");
        var out = {};
        for (var k in spec.object) {
            if (spec.object.hasOwnProperty(k)) {
                var {err, value} = objectValueDecoder(spec.object[k], ctx);
                if (err) return error(spec, data, err);
                var {err, decoded} = decode(value, data[k], ctx);
                if (err) return error(spec, data, err);
                out[k] = decoded;
            }
        }
        return {decoded: out};
    }
    
    function decodeOtherThan(spec, data, ctx) {
        var {err, value} = encode(spec.other_than, ctx);
        if (err) return error(spec, data, err);
        if (data != value) return {decoded: data};
        return error(spec, data, "no_match");
    }
    

    var anyConditions = {
        "text": (data) => { return typeof(data) === 'string' },
        "number": (data) => { return typeof(data) === 'number' },
        "boolean": (data) => { return typeof(data) === 'boolean' },
        "object": (data) => { return typeof(data) === 'object' },
        "list": (data) => { return Array.isArray(data) }
    }

    function decodeAny(spec, data, ctx) {
        if (data == undefined || data == null) return error(spec, data, "no_data");
        var d = anyConditions[spec.any];
        if (!d || !d(data)) return error(spec, data, "no_match");
        return {decoded: data}
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
                if (spec.other_than) return decodeOtherThan(spec, data, ctx);
                if (spec.one_of) return decodeOne(spec, data, ctx);
                if (spec.json) return decodeJson(spec, data, ctx);
                if (spec.size) return decodeSize(spec, data, ctx);
                return error(spec, data, "decoder_not_supported");
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
        var {err, value} = encode(spec, data, state.model);
        if (err) return err;
        log("[core] merging into model", value);
        Object.assign(state.model, value);
        log("[core] new model", state.model);
    }

    function log(msg, data) {
        if (state.app.settings.debug) console.log(msg, data);
    }
    
    function selectUpdate(msg, update, ctx) {
        var clauses = update[msg];
        if (!clauses || !clauses.length) return error(msg, ctx, "no_update_implemented");
        for (var i=0; i<clauses.length; i++) {
            var c = clauses[i];
            const { err, value } = encode(c.condition, ctx);
            log("[core] condition", { 
                condition: c.condition,
                context: ctx, 
                error: err, 
                value: value
            });
            if (err) return error(c.condition, model, err);
            if (value) return {spec: c};
        }
        return error(clauses, ctx, "all_conditions_failed");
    }

    function _update(ev) {
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
        var ctx = Object.assign({}, state.model, data);
        var {err, spec} = selectUpdate(msg, update, ctx);
        if (err) {
            console.error("Update error", err);
            return;
        } 
        
        log("[core] update spec", spec);
        var err = updateModel(spec.model, ctx);
        if (err) {
            console.error("Update error", err);
            return;
        }
        const t2 = new Date();
        applyCmds(encoders, state.effects, spec.cmds, state.model);
        const t3 = new Date();
        if (state.app.settings.telemetry) {
            console.log("[core]"
                + "[decode " + (t1.getMilliseconds() - t0.getMilliseconds()) + "ms]"
                + "[update " + (t2.getMilliseconds() - t1.getMilliseconds()) + "ms]"
                + "[cmds " + (t3.getMilliseconds() - t2.getMilliseconds()) + "ms]");
        }
    }

    function update(ev) {
        setTimeout(function() {
            _update(ev);
        }, 0)
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
