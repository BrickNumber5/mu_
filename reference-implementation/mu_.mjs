// # `mu_.mjs` — Javascript bindings for the `mu_.wasm` interpreter
//
// All uncommented public methods are thin wrappers around their WebAssembly
// counterparts, see `mu_.wat` for descriptions
//
// (C) 2025 Brielle Hoff --- Dual licensed under CC BY-NC 4.0 and MIT.

// Magic to import the WebAssembly module in either Deno or on the web
const module_url = URL.parse("./mu_.wasm", import.meta.url);
const module = typeof Deno === "object"
             ? await WebAssembly.compile(await Deno.readFile(module_url))
             : await WebAssembly.compileStreaming(fetch(module_url));

// You can't just pass Javascript functions to WebAssembly as funcrefs (no that
// would be too easy) so you have to use this incredibly janky hack where you
// import the function into a tiny module which does nothing but re-export the
// function in order to wrap it in the magic metadata that tells WebAssembly
// that it is permissible to use. Hopefully there will be a better way to do
// this at some point in the future.
const launder_js_function = (tiny_module => f => {
    const i = new WebAssembly.Instance(tiny_module, { ns: { f } });
    return i.exports.f;
})(await WebAssembly.compile(new Uint8Array([
    0x00, 0x61, 0x73, 0x6d, // wasm magic
    0x01, 0x00, 0x00, 0x00, // version
    0x01, 0x07,             // types section (id 1) --- 7 bytes
    0x01,                   //     1 type
    0x60,                   //     function (0x60)
    0x02, 0x7f, 0x7f,       //         2 inputs: i32 (0x7f) i32 (0x7f)
    0x01, 0x7f,             //         1 output: i32 (0x7f)
    0x02, 0x08,             // import section (id 2) --- 8 bytes
    0x01,                   //     1 import
    0x02, 0x6e, 0x73,       //     namespace: "ns"
    0x01, 0x66,             //     name: "f"
    0x00, 0x00,             //     function (magic 0) #0
    0x07, 0x05,             // export section (id 7) --- 5 bytes
    0x01,                   //     1 export
    0x01, 0x66,             //     name: "f"
    0x00, 0x00              //     function (0) #0
])));



export class Interpreter {
    static #builder_token = Symbol();

    // The builder method for Interpreter
    // This needs to be asynchronous for maximal efficiency and thus cannot be
    // a constructor, necessitating the use of a builder.
    //
    // To add system operations add them as entries of the sys property when
    // calling. Handlers should be functions taking in a (interpreter, arg, env)
    // triple and returning a result.
    //
    // For example you could instantiate using:
    // ```
    // Interpreter.instantiate({ sys: {
    //     "console:log": (mu_, arg, env) => {
    //         console.log(mu_.show(mu_.eval(arg, env)));
    //     },
    //     "math:random": (mu_, arg, env) => {
    //         return Math.floor(Math.random() * (2 ** 30));
    //     },
    // } })
    // ```
    // to provide a console log system function and random system function
    static async instantiate({ sys = {} } = {}) {
        const module_instance = await WebAssembly.instantiate(module);
        const instance = new this(Interpreter.#builder_token, module_instance);
        for (const [name, op] of Object.entries(sys)) {
            module_instance.exports.register_system_operation(
                instance.#inter_string(name),
                launder_js_function((arg, env) =>
                    instance.#conv(op(instance, arg, env)))
            );
        }
        return instance;
    }

    #bindings;

    constructor(builder_token, instance) {
        if (Interpreter.#builder_token !== builder_token) {
            throw new TypeError(
                "use await Interpreter.instantiate() to instantiate an interpreter"
            );
        }
        this.#bindings = instance.exports;
    }

    cons(head, tail) {
        return this.#bindings.cons(this.#conv(head), this.#conv(tail));
    }

    head(cell) {
        return this.#bindings.head(this.#conv(cell));
    }

    tail(cell) {
        return this.#bindings.tail(this.#conv(cell));
    }

    lookup(symbol, environment) {
        return this.#bindings.lookup(
            this.#conv(symbol),
            this.#conv(environment)
        );
    }

    match(value, pattern, environment = 0) {
        return this.#bindings.match(
            this.#conv(value),
            this.#conv(pattern),
            this.#conv(environment)
        );
    }

    eval(expression, environment = 0, anchor = null) {
        anchor ??= this.#bindings.gc_get_anchor();
        return this.#bindings.eval(
            this.#conv(expression),
            this.#conv(environment),
            anchor
        );
    }

    gc_get_anchor() {
        return this.#bindings.gc_get_anchor();
    }

    gc_collect(preserve, anchor) {
        return this.#bindings.gc_collect(this.#conv(preserve), anchor);
    }

    parse(str) {
        const { off, len } = this.#syalloc_string(str);
        return this.#bindings.parse(off, len);
    }

    // Method for rendering a mu_ object (which will just be an i32) as a
    // readable string. Implemented directly in Javascript as it is not part of
    // the core interpreter.
    //
    // The method chooses to render atoms without corresponding names as their
    // numeric representation as a u31 prefixed by the unicode symbol №.
    // Since the specification does not say anything about the interpretation
    // of characters outside the ascii range, this has no chance of colliding
    // with any code which is fully spec-compliant.
    //
    // This method only uses the dot symbol when it has to, always preferring
    // to render lists as much as it can.
    show(obj) {
        obj = this.#conv(obj);
        if (obj > 0) {
            const [ off, len ] = this.#bindings.lookup_interred_string(obj);
            if (len === -1) {
                return '№' + obj.toString();
            } else {
                const buf = new Uint8Array(
                    this.#bindings.stringyard.buffer,
                    off,
                    len
                );
                return this.#text_decoder.decode(buf);
            }
        } else {
            let str = '(';
            let first = true;
            while (obj < 0) {
                if (first) first = false;
                else       str += ' ';
                str += this.show(this.head(obj));
                obj  = this.tail(obj);
            }

            if (obj > 0) {
                str += " . ";
                str += this.show(obj);
            }

            str += ')';
            return str;
        }
    }

    // Convert a Javascript object into a mu_ one as best as possible
    // Converts arrays to lists and atoms to their atom numbers.
    #conv(obj) {
        if (typeof obj == "number") {
            return obj;
        } else if (typeof obj == "string") {
            return this.parse(obj);
        } else if (Array.isArray(obj)) {
            return obj.reduceRight(
                (acc, val) => this.cons(val, acc),
                this.#conv(obj["tail"] ?? 0)
            );
        } else if (obj == null) {
            return 0;
        }
    }

    // Inter a Javascript string into the mu_ interpreter
    #inter_string(str) {
        const { off, len } = this.#syalloc_string(str);
        return this.#bindings.inter_string(off, len);
    }

    #text_encoder = new TextEncoder();
    #text_decoder = new TextDecoder();

    // Allocate a javascript string into the mu_ interpreter's space
    #syalloc_string(str) {
        // We ask for 3 bytes per UTF-16 unit since that is an upper bound
        const size = str.length * 3;
        const off  = this.#bindings.syalloc(size);
        const buf  = new Uint8Array(
            this.#bindings.stringyard.buffer,
            off,
            size
        );

        const { written: len } = this.#text_encoder.encodeInto(str, buf);

        return { off, len };
    }
}
