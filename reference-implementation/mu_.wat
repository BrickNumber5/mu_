;; # `mu_.wat` — A reference implementation for the mu_ programming language
;;
;; `mu_.wat` is handcrafted, unfolded, and well commented WebAssembly text
;; program which can serve suitably both as an implementation in its own right
;; and as a template for ports to other assembly and programming languages.
;; See `mu_.mjs` for Javascript bindings
;;
;; This is version `r0.2i1` which implements `r0.2` of the mu_ specification.
;;
;; To compile, run: `wat2wasm --enable-multi-memory --enable-tail-call mu_.wat`
;;
;; ## Exposed Details
;;
;; All items are uniformly represented as 32 bit signed integers, with positive
;; numbers representing atoms in the obvious way and negative numbers
;; representing cons cells as their negative offsets into the cons cell stack.
;;
;; There is a string yard, a simple memory buffer and allocator `syalloc` which
;; the embedder can write strings into as a pre-condition to calling interpreter
;; methods which expect strings.
;;
;; `mu_.wat` exports the following bindings (in order of definition)
;;   - `cons`          : Construct a cons cell
;;   - `head`          : Take the head of a cons cell
;;   - `tail`          : Take the tail of a cons cell
;;   - `lookup`        : Look up a symbol in an environment
;;   - `match`         : Match a value against a pattern in a base environment
;;   - `stringyard`    : A buffer for the embedder to write strings (such as
;;                       program source code or atom names) into
;;   - `syalloc`       : Allocate space in the string yard for a new string
;;   - `inter_string`  : Take an offset and length (in bytes) into the string
;;                       yard and inter the string onto the internment stack,
;;                       returning its atom number
;;   - `lookup_interred_string` : Given an atom, return the offset and length
;;                                into the string yard of that atom's name,
;;                                yielding -1, -1 if it is unnamed
;;   - `parse`         : Parse a string in the string yard to a mu_ value
;;   - `eval`          : Evaluate an expression in an environment (then gc)
;;   - `register_system_operation` : Given an atom and a funcref register a
;;                                   system operation with that name handled by
;;                                   that handler
;;   - `gc_get_anchor` : Get an anchor for the garbage collector
;;                       Usually, you should call this and pass the result as
;;                       the third argument to `eval`. Read the comments in the
;;                       garbage collection section which offer more detail on
;;                       how garbage collection is implemented before using the
;;                       the garbage collection mechanism in any other way
;;   - `gc_collect`    : Run the garbage collector
;;
;; (C) 2025 Brielle Hoff --- Dual licensed under CC BY-NC 4.0 and MIT.

(module
    ;; ---------- Cons Cells ----------
    ;; Each cell is (head, tail)
    ;; $cons_cells_top points to the last allocated cons cell
    (memory $cons_cells 1)
    (data (memory $cons_cells) (i32.const 0) "\00\00\00\00\00\00\00\00")
    ;; Points to the last element of the stack
    (global $cons_cells_top (mut i32) (i32.const 0))

    ;; Construct a cell
    (func $cons (export "cons")
        (param $head i32) (param $tail i32)
        (result i32)
        (local $top i32)

        ;; Adjust the stack pointer
        global.get $cons_cells_top
        i32.const 8
        i32.add
        local.tee $top
        global.set $cons_cells_top

        ;; Write the head value
        local.get $top
        local.get $head
        i32.store (memory $cons_cells)

        ;; Write the tail value
        local.get $top
        i32.const 4
        i32.add
        local.get $tail
        i32.store (memory $cons_cells)

        ;; Negate the offset into the stack to produce the representation
        i32.const 0
        local.get $top
        i32.sub
    )

    ;; Take the head of a cell
    (func $head (export "head")
        (param $cell i32)
        (result i32)

        ;; Negate the representation to get the offset into the stack
        i32.const 0
        local.get $cell
        i32.sub

        ;; Read the head value
        i32.load (memory $cons_cells)
    )

    ;; Take the tail of a cell
    (func $tail (export "tail")
        (param $cell i32)
        (result i32)

        ;; Negate the representation to get the offset into the stack and
        ;; shift by four to get the tail instead of the head in one step
        i32.const 4
        local.get $cell
        i32.sub

        ;; Read the tail value
        i32.load (memory $cons_cells)
    )

    ;; ---------- Primitive Interpreter Operations ----------

    ;; Lookup a symbol in an environment
    (func $lookup (export "lookup")
        (param $symbol i32)
        (param $environment i32)
        (result i32)
        (local $binding i32)

        (loop $loop (result i32)
            local.get $environment
            i32.eqz
            (if (result i32)
                (then
                    ;; We've exhausted the environment, map a symbol to itself
                    local.get $symbol
                )
                (else
                    ;; Get the first binding in the environment
                    local.get $environment
                    call $head
                    local.tee $binding

                    call $head
                    local.get $symbol
                    i32.eq
                    (if (result i32)
                        (then
                            ;; If it matches, return the bound value
                            local.get $binding
                            call $tail
                        )
                        (else
                            ;; Otherwise, continue over the remaining bindings
                            local.get $environment
                            call $tail
                            local.set $environment
                            br $loop
                        )
                    )
                ))
        )
    )

    ;; Match a value against a pattern in a base environment
    (func $match (export "match")
        (param $value i32)
        (param $pattern i32)
        (param $environment i32)
        (result i32)

        local.get $pattern
        i32.eqz
        (if (result i32)
            (then
                ;; The pattern is (), don't introduce any bindings
                local.get $environment
            )
            (else
                local.get $pattern
                i32.const 0
                i32.gt_s
                (if (result i32)
                    (then
                        ;; The pattern is a positive atom, add a binding to the
                        ;; environment
                        local.get $pattern
                        local.get $value
                        call $cons
                        local.get $environment
                        call $cons
                    )
                    (else
                        ;; The pattern is a cons cell, recurse

                        ;; Match the value head against the pattern head
                        local.get $value
                        call $head
                        local.get $pattern
                        call $head

                        ;; Match the value tail against the pattern tail
                        local.get $value
                        call $tail
                        local.get $pattern
                        call $tail
                        local.get $environment

                        call $match
                        call $match
                    )
                )
            )
        )
    )

    ;; ---------- String Yard ----------
    ;; The stringyard is a place for the embedding application to place strings
    ;; it wishes to pass to the interpreter.
    ;; Call syalloc(size) to acquire size bytes from the yard to place a string
    (memory $stringyard (export "stringyard") 1)
    (data (memory $stringyard) (i32.const 0)
        "~~true..~~false."
        "~~head..~~tail..~~cons.."
        "~~lte...~~eq...."
        "~~add...~~sub..."
        "~~and...~~or....~~not..."
        "~~sl....~~sr...."
        "~~env...~~sys...")
    (global $stringyard_top (mut i32) (i32.const 128))

    ;; Allocate space on the string yard to place a string of size bytes
    ;; mu_ never uses this internally (nor modifies the string yard at all)
    ;; it only uses it for its initial strings and as a dumping ground for the
    ;; embedder to place strings into for it to use.
    (func (export "syalloc")
        (param $size i32)
        (result i32)
        (local $top i32)

        ;; Adjust the available space top
        ;; This implementation is extremely simple because we don't do any
        ;; sophisticated memory management for strings.
        global.get $stringyard_top
        local.tee $top
        local.get $size
        i32.add
        global.set $stringyard_top

        local.get $top
    )

    ;; Compare two strings in the string yard
    (func $str_eq
        (param $a_off i32)
        (param $a_len i32)
        (param $b_off i32)
        (param $b_len i32)
        (result i32)
        (local $a_end i32)

        ;; Pre-check the string lengths
        local.get $a_len
        local.get $b_len
        i32.eq
        (if
            (then
                ;; Convert len to end for simpler iteration
                local.get $a_off
                local.get $a_len
                i32.add
                local.set $a_end

                ;; Loop over the bytes in the strings
                (block $break_loop
                    (loop $loop
                        ;; If we've reached the end, the strings are equal
                        local.get $a_off
                        local.get $a_end
                        i32.eq
                        (if
                            (then
                                i32.const 1
                                return
                            )
                        )

                        ;; Compare bytes, break if unequal
                        local.get $a_off
                        i32.load8_u (memory $stringyard)
                        local.get $b_off
                        i32.load8_u (memory $stringyard)
                        i32.ne
                        br_if $break_loop

                        ;; Increment the offsets into the strings
                        local.get $a_off
                        i32.const 1
                        i32.add
                        local.set $a_off
                        local.get $b_off
                        i32.const 1
                        i32.add
                        local.set $b_off

                        br $loop
                    )
                )
            )
        )

        ;; The strings are different
        i32.const 0
    )

    ;; String internment
    (memory $string_internment_stack 1)
    ;; [{ offset: i32, len: u16, system_opcode: u16 }]
    (data (memory $string_internment_stack) (i32.const 0)
        "\00\00\00\00" "\00\00" "\00\00" ;; <ensure no string at 0>
        "\00\00\00\00" "\06\00" "\00\00" ;; ~~true  (6)
        "\08\00\00\00" "\07\00" "\00\00" ;; ~~false (7)
        "\10\00\00\00" "\06\00" "\00\00" ;; ~~head  (6)
        "\18\00\00\00" "\06\00" "\00\00" ;; ~~tail  (6)
        "\20\00\00\00" "\06\00" "\00\00" ;; ~~cons  (6)
        "\28\00\00\00" "\05\00" "\00\00" ;; ~~lte   (5)
        "\30\00\00\00" "\04\00" "\00\00" ;; ~~eq    (4)
        "\38\00\00\00" "\05\00" "\00\00" ;; ~~add   (5)
        "\40\00\00\00" "\05\00" "\00\00" ;; ~~sub   (5)
        "\48\00\00\00" "\05\00" "\00\00" ;; ~~and   (5)
        "\50\00\00\00" "\04\00" "\00\00" ;; ~~or    (4)
        "\58\00\00\00" "\05\00" "\00\00" ;; ~~not   (5)
        "\60\00\00\00" "\04\00" "\00\00" ;; ~~sl    (4)
        "\68\00\00\00" "\04\00" "\00\00" ;; ~~sr    (4)
        "\70\00\00\00" "\05\00" "\00\00" ;; ~~env   (5)
        "\78\00\00\00" "\05\00" "\00\00" ;; ~~sys   (5)
    )
    ;; Points “One past the end” of the stack
    (global $string_internment_stack_top (mut i32) (i32.const 136))

    ;; Inter a string from the stringyard onto the string internment stack
    (func $inter_string (export "inter_string")
        (param $off i32)
        (param $len i32)
        (result i32)
        (local $idx i32)

        ;; Initialize idx to zero
        i32.const 0
        local.set $idx

        ;; Loop over the strings in the internment stack
        (block $scan
            (block $break_loop
                (loop $loop
                    ;; If we reached the end of the internment stack, we need
                    ;; to add a new string
                    local.get $idx
                    global.get $string_internment_stack_top
                    i32.eq
                    br_if $break_loop

                    ;; Load the idx'th string from the stack and compare to the
                    ;; string to be interred, if equal we found a match
                    local.get $idx
                    i32.load (memory $string_internment_stack)
                    local.get $idx
                    i32.const 4
                    i32.add
                    i32.load16_u (memory $string_internment_stack)
                    local.get $off
                    local.get $len
                    call $str_eq
                    br_if $scan

                    ;; Increment idx
                    local.get $idx
                    i32.const 8
                    i32.add
                    local.set $idx

                    br $loop
                )
            )

            ;; We need to add a new string

            ;; Store the string onto the internment stack
            local.get $idx
            local.get $off
            i32.store (memory $string_internment_stack)
            local.get $idx
            i32.const 4
            i32.add
            local.get $len
            i32.store16 (memory $string_internment_stack)
            local.get $idx
            i32.const 6
            i32.add
            i32.const 0
            i32.store16 (memory $string_internment_stack)

            ;; Adjust the top of the internment stack
            local.get $idx
            i32.const 8
            i32.add
            global.set $string_internment_stack_top
        )

        local.get $idx

        ;; Flip bit 29 to decrease the odds the numeric representation occurs
        ;; by chance when doing ordinary calculations
        i32.const 0x20_00_00_00
        i32.xor
    )

    ;; Lookup an interred string or return -1 -1 if not an interred string atom
    ;; String atom detection is on a best effort basis as all string atoms have
    ;; a numeric value it is always possible that a string atom is created by
    ;; chance via a numeric calculation.
    ;; String atoms are given unusual numbers to minimize the likelihood of this
    ;; but it remains possible.
    (func (export "lookup_interred_string")
        (param $idx i32)
        (result i32 i32)

        ;; Undo the flip of bit 29
        local.get $idx
        i32.const 0x20_00_00_00
        i32.xor
        local.set $idx

        (block $unnamed
            ;; Check that the index is in bounds
            local.get $idx
            global.get $string_internment_stack_top
            i32.ge_u
            br_if $unnamed

            ;; Check that the index is properly aligned
            local.get $idx
            i32.const 0x7
            i32.and
            i32.const 0
            i32.ne
            br_if $unnamed

            ;; This could be an interred string, load its properties

            ;; Load the offset
            local.get $idx
            i32.load (memory $string_internment_stack)

            ;; Load the length
            local.get $idx
            i32.const 4
            i32.add
            i32.load16_u (memory $string_internment_stack)

            return
        )

        ;; This isn't an interred string, return the failure sentinel
        i32.const -1
        i32.const -1
        return
    )

    ;; ---------- Parsing ----------

    ;; Parse mu_ source text to an expression
    (func $parse (export "parse")
        (param $off i32)
        (param $len i32)
        (result i32)
        (local $end i32)

        ;; Convert len to end for easier iteration
        local.get $off
        local.get $off
        local.get $len
        i32.add
        local.tee $end

        ;; Skip leading whitespace
        call $parse_skip_ws

        ;; Parse an expression
        local.get $end
        call $parse_expr

        ;; Skip trailing whitespace
        local.get $end
        call $parse_skip_ws

        drop
    )

    ;; Parse an expression
    ;; Returns expr, off
    (func $parse_expr
        (param $off i32)
        (param $end i32)
        (result i32 i32)

        ;; Check for a left parenthesis
        local.get $off
        local.get $end
        call $parse_peek
        i32.const 0x28 ;; LEFT PARENTHESIS
        i32.eq
        (if (result i32)
            (then
                ;; There is a left parenthesis, this is a list/cell

                ;; Eat the left parenthesis
                local.get $off
                i32.const 1
                i32.add

                ;; Parse the rest of the list/cell
                local.get $end
                return_call $parse_list_inner
            )
            (else
                ;; There isn't a left parenthesis, this is an atom

                ;; Parse an atom
                local.get $off
                local.get $end
                return_call $parse_atom
            )
        )
    )

    ;; Parse a list sans leading paren
    ;; Returns expr, off
    (func $parse_list_inner
        (param $off i32)
        (param $end i32)
        (result i32 i32)
        (local $chr i32)

        ;; Skip leading whitespace
        local.get $off
        local.get $end
        call $parse_skip_ws

        ;; Check for a dot
        local.get $end
        call $parse_peek
        local.tee $chr
        i32.const 0x2e ;; FULL STOP
        i32.eq
        (if (param i32) (result i32)
            (then
                ;; There is a dot, parse one final tail expression

                ;; Eat the dot
                i32.const 1
                i32.add

                ;; Skip whitespace after the dot
                local.get $end
                call $parse_skip_ws

                ;; Parse an expression
                local.get $end
                call $parse_expr

                ;; Skip trailing whitespace before the closing parenthesis
                local.get $end
                call $parse_skip_ws

                ;; Eat the closing paren
                i32.const 1
                i32.add
                return
            )
        )

        ;; Check for a right parenthesis
        local.get $chr
        i32.const 0x29 ;; RIGHT PARENTHESIS
        i32.eq
        (if (param i32) (result i32)
            (then
                ;; There is a right parenthesis, return the 0 atom

                local.set $off

                ;; Load the value zero
                i32.const 0

                ;; Eat the right parenthesis
                local.get $off
                i32.const 1
                i32.add
                return
            )
        )

        ;; There are more items remaining

        ;; Parse an expression
        local.get $end
        call $parse_expr

        ;; Parse the rest of the list
        local.get $end
        call $parse_list_inner

        ;; Combine the results
        local.set $off
        call $cons
        local.get $off
    )

    ;; Parse an atom
    ;; Returns expr, off
    (func $parse_atom
        (param $off i32)
        (param $end i32)
        (result i32 i32)
        (local $chr i32)
        (local $nex i32)

        ;; Determine the extent of the atom
        local.get $off
        local.get $off
        (block $break_loop (param i32) (result i32)
            (loop $loop (param i32) (result i32)
                local.get $end
                call $parse_peek
                local.tee $chr

                ;; Break for whitespace or end
                i32.const 32
                i32.le_u
                br_if $break_loop

                ;; Break for lparen
                local.get $chr
                i32.const 0x28
                i32.eq
                br_if $break_loop

                ;; Break for rparen
                local.get $chr
                i32.const 0x29
                i32.eq
                br_if $break_loop

                ;; Break for dot
                local.get $chr
                i32.const 0x2e
                i32.eq
                br_if $break_loop

                i32.const 1
                i32.add
                br $loop
            )
        )

        ;; Inter the atom
        local.tee $nex
        local.get $off
        i32.sub
        call $inter_string

        local.get $nex
    )

    ;; Skip whitespace
    (func $parse_skip_ws
        (param $off i32)
        (param $end i32)
        (result i32)

        ;; Loop over bytes
        local.get $off
        (block $break_loop (param i32) (result i32)
            (loop $loop (param i32) (result i32)
                local.get $end
                call $parse_peek

                ;; If the value is in [1, 32] it is whitespace
                i32.const 1
                i32.sub
                i32.const 32
                i32.ge_u
                br_if $break_loop

                i32.const 1
                i32.add
                br $loop
            )
        )
    )

    ;; Peek at a byte -- off, byte
    (func $parse_peek
        (param $off i32)
        (param $end i32)
        (result i32 i32)

        local.get $off

        ;; If at the end of the input, return 0
        (block $not_end (param i32) (result i32)
            local.get $off
            local.get $end
            i32.ne
            br_if $not_end

            i32.const 0
            return
        )

        ;; Get a byte
        local.get $off
        i32.load8_u (memory $stringyard)
    )

    ;; ---------- Evaluation : The Heart of the Interpreter ----------

    ;; Table of builtins and system operations
    ;; The former take slots 0 - 16 while the latter start in slot 32
    (table 64 funcref)
    (elem (i32.const 0)
        $eval_builtin_quote
        $eval_builtin_true
        $eval_builtin_false
        $eval_builtin_head
        $eval_builtin_tail
        $eval_builtin_cons
        $eval_builtin_lte
        $eval_builtin_eq
        $eval_builtin_add
        $eval_builtin_sub
        $eval_builtin_and
        $eval_builtin_or
        $eval_builtin_not
        $eval_builtin_sl
        $eval_builtin_sr
        $eval_builtin_env
        $eval_builtin_sys
    )
    (elem (i32.const 32) $system_operation_zero)

    (type $invokable (func
        (param $arguments i32)
        (param $environment i32)
        (param $gc_anchor i32)
        (result i32)
    ))

    ;; Evaluate an expression in an environment, then perform garbage
    ;; collection from the given anchor.
    ;;
    ;; A garbage collection anchor is passed to this function so that the
    ;; needed garbage collection information can be maintained over tail calls.
    ;;
    ;; For the end user, you should probably just pass gc_get_anchor() unless
    ;; you would otherwise call gc_collect(<result of eval>, <some anchor>)
    ;; immediately after anyways.
    (func $eval (export "eval")
        (param $expression i32)
        (param $environment i32)
        (param $gc_anchor i32)
        (result i32)
        (local $receiver i32)

        ;; Determine whether the expression is an atom or cons cell
        local.get $expression
        i32.const 0
        i32.ge_s
        (if (result i32)
            (then
                ;; This is an atom, determine whether it is 0
                local.get $expression
                i32.eqz
                (if (result i32)
                    (then
                        ;; The 0 atom evaluates to itself
                        i32.const 0
                    )
                    (else
                        ;; Positive atoms are looked up in the environment
                        local.get $expression
                        local.get $environment
                        call $lookup
                    )
                )

                ;; Run garbage collection
                local.get $gc_anchor
                call $gc_collect
            )
            (else
                ;; This is a cons cell, it should be a list representing an
                ;; invocation of either a user defined receiver or a builtin

                ;; Evaluate the head to determine the receiver
                local.get $expression
                call $head
                local.get $environment
                global.get $cons_cells_top
                call $eval
                local.set $receiver

                ;; Load the arguments
                local.get $expression
                call $tail

                ;; Load the environment
                local.get $environment

                ;; Load the garbage collection anchor
                local.get $gc_anchor

                ;; Load the receiver
                local.get $receiver

                ;; Check whether the receiver is an atom
                local.get $receiver
                i32.const 0
                i32.ge_s
                (if (param i32) (param i32) (param i32) (param i32) (result i32)
                    (then
                        ;; The receiver is an atom, this is a builtin call
                        ;; Look up the builtin in the table of builtins

                        ;; Zero out bit 29
                        i32.const 0xDF_FF_FF_FF
                        i32.and

                        ;; Shift the value to get an index into the table
                        ;; (which increments by one each time) instead of the
                        ;; memory (which increments by eight each time)
                        i32.const 3
                        i32.shr_u

                        ;; Invoke the specified builtin
                        return_call_indirect (type $invokable)
                    )
                    (else
                        ;; Run the user defined receiver handling
                        return_call $eval_invoke_user_defined
                    )
                )
            )
        )
    )

    ;; Evaluates each item in a list, forming a new list
    (func $eval_list
        (param $expression_list i32)
        (param $environment i32)
        (result i32)

        ;; Check whether the list is empty
        local.get $expression_list
        i32.eqz
        (if (result i32)
            (then
                ;; This is an empty list, we've evaluated the entire list
                i32.const 0
            )
            (else
                ;; This is a non-empty list, evaluate the first element,
                ;; recurse over the remaining elements, and recombine

                ;; Evaluate the head
                local.get $expression_list
                call $head
                local.get $environment
                global.get $cons_cells_top
                call $eval

                ;; Evaluate each item in the tail
                local.get $expression_list
                call $tail
                local.get $environment
                call $eval_list

                ;; Recombine the evaluated head and tail
                call $cons
            )
        )
    )

    ;; Evaluate an invocation of a user defined receiver (function or macro)
    (func $eval_invoke_user_defined
        (param $arguments i32)
        (param $environment i32)
        (param $gc_anchor i32)
        (param $receiver i32)
        (result i32)
        (local $function_environment i32)
        (local $preserved i32)

        (block $skip_function_ops
            ;; Check if the receiver has a third element (is a function)
            local.get $receiver
            call $tail
            call $tail
            local.tee $function_environment
            i32.eqz
            br_if $skip_function_ops

            ;; If it is, do the following, otherwise skip

            ;; Evaluate each argument in the list of arguments
            local.get $arguments
            local.get $environment
            call $eval_list
            local.set $arguments

            ;; Update the environment to use to the specified one instead of
            ;; the one belonging to the caller
            local.get $function_environment
            call $head
            local.set $environment
        )

        ;; Get the body
        local.get $receiver
        call $tail
        call $head

        ;; Get the arguments
        local.get $arguments

        ;; Get the pattern
        local.get $receiver
        call $head

        ;; Match the arguments against the pattern
        local.get $environment
        call $match

        ;; Run garbage collection
        ;; This garbage collection is unnecessary for ensuring the final size
        ;; of the cons cell stack as a garbage collection from the same point
        ;; will be run downstream of the tail call which will be made.
        ;; However, this garbage collection does help to keep down the level of
        ;; garbage when repeatedly tail evaluating from one user defined
        ;; receiver into another as is extremely common in real mu_ programs.
        call $cons
        local.get $gc_anchor
        call $gc_collect
        local.tee $preserved
        call $head
        local.get $preserved
        call $tail

        ;; Tail evaluate the body
        local.get $gc_anchor
        return_call $eval
    )

    ;; Evaluate an invocation of the () builtin
    (func $eval_builtin_quote
        (param $arguments i32)
        (param $environment i32)
        (param $gc_anchor i32)
        (result i32)
        ;; Get the first argument
        local.get $arguments
        call $head

        ;; Run garbage collection
        local.get $gc_anchor
        call $gc_collect
    )

    ;; Evaluate an invocation of the ~~true builtin
    (func $eval_builtin_true
        (param $arguments i32)
        (param $environment i32)
        (param $gc_anchor i32)
        (result i32)
        ;; Get the first argument
        local.get $arguments
        call $head

        ;; Tail evaluate it
        local.get $environment
        local.get $gc_anchor
        return_call $eval
    )

    ;; Evaluate an invocation of the ~~false builtin
    (func $eval_builtin_false
        (param $arguments i32)
        (param $environment i32)
        (param $gc_anchor i32)
        (result i32)
        ;; Get the second argument
        local.get $arguments
        call $tail
        call $head

        ;; Tail evaluate it
        local.get $environment
        local.get $gc_anchor
        return_call $eval
    )

    ;; Evaluate an invocation of the ~~head builtin
    (func $eval_builtin_head
        (param $arguments i32)
        (param $environment i32)
        (param $gc_anchor i32)
        (result i32)
        ;; Get the first argument
        local.get $arguments
        call $head

        ;; Evaluate it
        local.get $environment
        global.get $cons_cells_top
        call $eval

        ;; Get its head
        call $head

        ;; Run garbage collection
        local.get $gc_anchor
        call $gc_collect
    )

    ;; Evaluate an invocation of the ~~tail builtin
    (func $eval_builtin_tail
        (param $arguments i32)
        (param $environment i32)
        (param $gc_anchor i32)
        (result i32)
        ;; Get the first argument
        local.get $arguments
        call $head

        ;; Evaluate it
        local.get $environment
        global.get $cons_cells_top
        call $eval

        ;; Get its tail
        call $tail

        ;; Run garbage collection
        local.get $gc_anchor
        call $gc_collect
    )

    ;; Evaluate an invocation of the ~~cons builtin
    (func $eval_builtin_cons
        (param $arguments i32)
        (param $environment i32)
        (param $gc_anchor i32)
        (result i32)
        ;; Get the first argument
        local.get $arguments
        call $head

        ;; Evaluate it
        local.get $environment
        global.get $cons_cells_top
        call $eval

        ;; Get the second argument
        local.get $arguments
        call $tail
        call $head

        ;; Evaluate it
        local.get $environment
        global.get $cons_cells_top
        call $eval

        ;; Cons them together
        call $cons

        ;; Run garbage collection
        local.get $gc_anchor
        call $gc_collect
    )

    ;; Evaluate an invocation of the ~~lte builtin
    (func $eval_builtin_lte
        (param $arguments i32)
        (param $environment i32)
        (param $gc_anchor i32)
        (result i32)
        ;; Prepare the ~~true and ~~false atoms
        i32.const 0x20_00_00_08 ;; ~~true
        i32.const 0x20_00_00_10 ;; ~~false

        ;; Get the first argument
        local.get $arguments
        call $head

        ;; Evaluate it
        local.get $environment
        global.get $cons_cells_top
        call $eval

        ;; Get the second argument
        local.get $arguments
        call $tail
        call $head

        ;; Evaluate it
        local.get $environment
        global.get $cons_cells_top
        call $eval

        ;; Select the appropriate atom (~~true or ~~false)
        ;; based on whether the first is less than or equal to the second
        i32.le_s
        select

        ;; Run garbage collection
        local.get $gc_anchor
        call $gc_collect
    )

    ;; Evaluate an invocation of the ~~eq builtin
    (func $eval_builtin_eq
        (param $arguments i32)
        (param $environment i32)
        (param $gc_anchor i32)
        (result i32)
        ;; Prepare the ~~true and ~~false atoms
        i32.const 0x20_00_00_08 ;; ~~true
        i32.const 0x20_00_00_10 ;; ~~false

        ;; Get the first argument
        local.get $arguments
        call $head

        ;; Evaluate it
        local.get $environment
        global.get $cons_cells_top
        call $eval

        ;; Get the second argument
        local.get $arguments
        call $tail
        call $head

        ;; Evaluate it
        local.get $environment
        global.get $cons_cells_top
        call $eval

        ;; Select the appropriate atom (~~true or ~~false)
        ;; based on whether the first is equal to the second
        i32.eq
        select

        ;; Run garbage collection
        local.get $gc_anchor
        call $gc_collect
    )

    ;; Evaluate an invocation of the ~~add builtin
    (func $eval_builtin_add
        (param $arguments i32)
        (param $environment i32)
        (param $gc_anchor i32)
        (result i32)
        ;; Get the first argument
        local.get $arguments
        call $head

        ;; Evaluate it
        local.get $environment
        global.get $cons_cells_top
        call $eval

        ;; Get the second argument
        local.get $arguments
        call $tail
        call $head

        ;; Evaluate it
        local.get $environment
        global.get $cons_cells_top
        call $eval

        ;; Add the arguments and take the result modulo 2 ^ 31
        i32.add
        i32.const 0x7F_FF_FF_FF
        i32.and

        ;; Run garbage collection
        local.get $gc_anchor
        call $gc_collect
    )

    ;; Evaluate an invocation of the ~~sub builtin
    (func $eval_builtin_sub
        (param $arguments i32)
        (param $environment i32)
        (param $gc_anchor i32)
        (result i32)
        ;; Get the first argument
        local.get $arguments
        call $head

        ;; Evaluate it
        local.get $environment
        global.get $cons_cells_top
        call $eval

        ;; Get the second argument
        local.get $arguments
        call $tail
        call $head

        ;; Evaluate it
        local.get $environment
        global.get $cons_cells_top
        call $eval

        ;; Subtract the arguments and take the result modulo 2 ^ 31
        i32.sub
        i32.const 0x7F_FF_FF_FF
        i32.and

        ;; Run garbage collection
        local.get $gc_anchor
        call $gc_collect
    )

    ;; Evaluate an invocation of the ~~and builtin
    (func $eval_builtin_and
        (param $arguments i32)
        (param $environment i32)
        (param $gc_anchor i32)
        (result i32)
        ;; Get the first argument
        local.get $arguments
        call $head

        ;; Evaluate it
        local.get $environment
        global.get $cons_cells_top
        call $eval

        ;; Get the second argument
        local.get $arguments
        call $tail
        call $head

        ;; Evaluate it
        local.get $environment
        global.get $cons_cells_top
        call $eval

        ;; Take the bitwise and of the arguments
        i32.and

        ;; Run garbage collection
        local.get $gc_anchor
        call $gc_collect
    )

    ;; Evaluate an invocation of the ~~or builtin
    (func $eval_builtin_or
        (param $arguments i32)
        (param $environment i32)
        (param $gc_anchor i32)
        (result i32)
        ;; Get the first argument
        local.get $arguments
        call $head

        ;; Evaluate it
        local.get $environment
        global.get $cons_cells_top
        call $eval

        ;; Get the second argument
        local.get $arguments
        call $tail
        call $head

        ;; Evaluate it
        local.get $environment
        global.get $cons_cells_top
        call $eval

        ;; Take the bitwise or of the arguments
        i32.or

        ;; Run garbage collection
        local.get $gc_anchor
        call $gc_collect
    )

    ;; Evaluate an invocation of the ~~not builtin
    (func $eval_builtin_not
        (param $arguments i32)
        (param $environment i32)
        (param $gc_anchor i32)
        (result i32)
        ;; Get the first argument
        local.get $arguments
        call $head

        ;; Evaluate it
        local.get $environment
        global.get $cons_cells_top
        call $eval

        ;; Take the bitwise negation of the least significant 31 bits
        i32.const 0x7F_FF_FF_FF
        i32.xor

        ;; Run garbage collection
        local.get $gc_anchor
        call $gc_collect
    )

    ;; Evaluate an invocation of the ~~sl builtin
    (func $eval_builtin_sl
        (param $arguments i32)
        (param $environment i32)
        (param $gc_anchor i32)
        (result i32)
        ;; Get the first argument
        local.get $arguments
        call $head

        ;; Evaluate it
        local.get $environment
        global.get $cons_cells_top
        call $eval

        ;; Get the second argument
        local.get $arguments
        call $tail
        call $head

        ;; Evaluate it
        local.get $environment
        global.get $cons_cells_top
        call $eval

        ;; Bit shift left the first argument by the second, keeping only the
        ;; least significant 31 bits
        i32.shl
        i32.const 0x7F_FF_FF_FF
        i32.and

        ;; Run garbage collection
        local.get $gc_anchor
        call $gc_collect
    )

    ;; Evaluate an invocation of the ~~sr builtin
    (func $eval_builtin_sr
        (param $arguments i32)
        (param $environment i32)
        (param $gc_anchor i32)
        (result i32)
        ;; Get the first argument
        local.get $arguments
        call $head

        ;; Evaluate it
        local.get $environment
        global.get $cons_cells_top
        call $eval

        ;; Get the second argument
        local.get $arguments
        call $tail
        call $head

        ;; Evaluate it
        local.get $environment
        global.get $cons_cells_top
        call $eval

        ;; Bit shift right the first argument by the second
        i32.shr_u

        ;; Run garbage collection
        local.get $gc_anchor
        call $gc_collect
    )

    ;; Evaluate an invocation of the ~~env builtin
    (func $eval_builtin_env
        (param $arguments i32)
        (param $environment i32)
        (param $gc_anchor i32)
        (result i32)
        ;; Get the environment
        local.get $environment

        ;; Run garbage collection
        local.get $gc_anchor
        call $gc_collect
    )

    ;; Evaluate an invocation of the ~~sys builtin
    (func $eval_builtin_sys
        (param $arguments i32)
        (param $environment i32)
        (param $gc_anchor i32)
        (result i32)

        ;; Get the argument (argument 2)
        local.get $arguments
        call $tail
        call $head
        local.get $environment

        ;; Call the handler
        local.get $arguments
        call $head
        i32.const 32
        i32.add
        call_indirect (type $system_operation_handler)

        ;; Run garbage collection
        local.get $gc_anchor
        call $gc_collect
    )

    ;; ---------- System Operation Registration ----------

    (type $system_operation_handler (func
        (param $argument i32)
        (param $environment i32)
        (result i32)
    ))

    (global $highest_system_opcode (mut i32) (i32.const 0))

    ;; Register a system operation under the designated name using the provided
    ;; handler. To be fully spec compliant this function should only be called
    ;; before any mu_ code has been evaluated.
    (func (export "register_system_operation")
        (param $operation_name i32)
        (param $handler funcref)
        (local $opcode i32)
        (local $size_delta i32)

        ;; Get the next available opcode
        global.get $highest_system_opcode
        i32.const 1
        i32.add
        local.tee $opcode
        global.set $highest_system_opcode

        ;; Resize the function table as necessary

        i32.const 1
        i32.const 32

        ;; Compute the table index
        local.get $opcode
        i32.const 32
        i32.add

        ;; Round up to the next power of two
        i32.clz
        i32.sub
        i32.shl

        ;; Compute the size delta
        table.size
        i32.sub
        local.tee $size_delta

        ;; Resize if the delta is positive
        i32.const 0
        i32.gt_s
        (if
            (then
                ref.null func
                local.get $size_delta
                table.grow
                drop
            )
        )

        ;; Set the designated slot
        local.get $opcode
        i32.const 32
        i32.add
        local.get $handler
        table.set

        ;; Update the string internment entry to indicate the opcode

        ;; Get the index into the internment stack from the atom number
        local.get $operation_name
        i32.const 0xDF_FF_FF_FF
        i32.and

        ;; Offset to the opcode entry
        i32.const 6
        i32.add

        ;; Write the opcode
        local.get $opcode
        i32.store16 (memory $string_internment_stack)
    )

    ;; (~~sys () ()) -- get mappings from system operation names to codes
    (func $system_operation_zero (type $system_operation_handler)
        (local $idx i32)
        (local $acc i32)
        (local $opcode i32)

        i32.const 0
        local.set $acc

        i32.const 0
        local.set $idx
        (loop $loop
            ;; Load the opcode
            local.get $idx
            i32.const 6
            i32.add
            i32.load16_u (memory $string_internment_stack)
            local.tee $opcode

            (block $skip_add (param i32)
                ;; If opcode is zero, this isn't a system operation, continue
                i32.eqz
                br_if $skip_add

                ;; Flip bit 29 of the index to get the atom number
                local.get $idx
                i32.const 0x20_00_00_00
                i32.xor

                ;; Add mapping from name to opcode to accumulator
                local.get $opcode
                call $cons
                local.get $acc
                call $cons
                local.set $acc
            )

            ;; Increment idx
            local.get $idx
            i32.const 8
            i32.add
            local.set $idx

            local.get $idx
            global.get $string_internment_stack_top
            i32.lt_u
            br_if $loop
        )

        local.get $acc
    )

    ;; ---------- Garbage Collector ----------
    ;; The garbage collection mechanism operates as follows:
    ;;   1. Acquire a garbage collection anchor (gc_get_anchor)
    ;;   2. Do something that might cause the allocation of garbage
    ;;   3. Call gc_collect(<preserve>, <anchor>) passing the value you want to
    ;;      keep as preserve. The response is a new value (earlier on the stack
    ;;      where possible) which is equivalent to the passed preserve value.
    ;;      All cons cells which are not directly or indirectly a dependency of
    ;;      the preserved value and which were allocated after the anchor was
    ;;      taken are removed.
    ;;
    ;; Note that evaluation performs a garbage collection step itself so the
    ;; manual use of this mechanism by the embedder is only necessary to clear
    ;; cells created through a means other than evaluation such as parsing.

    ;; Get a garbage collection anchor
    (func $gc_get_anchor (export "gc_get_anchor")
        (result i32)

        global.get $cons_cells_top
    )

    ;; Run the garbage collector
    (func $gc_collect (export "gc_collect")
        (param $preserve i32)
        (param $anchor i32)
        (result i32)
        (local $anchor_2 i32)

        ;; Take a second anchor, this represents where the cons stack grew to
        global.get $cons_cells_top
        local.set $anchor_2

        ;; Recursively copy the preserved element
        local.get $preserve
        local.get $anchor
        local.get $anchor_2
        call $gc_copy

        ;; Move the copied cells (the ones to be kept) down, overwriting the
        ;; range between the first and second anchors
        local.get $anchor
        i32.const 8
        i32.add
        local.get $anchor_2
        i32.const 8
        i32.add
        global.get $cons_cells_top
        local.get $anchor_2
        i32.sub
        memory.copy (memory $cons_cells)

        ;; Adjust the top of the stack down
        global.get $cons_cells_top
        local.get $anchor_2
        i32.sub
        local.get $anchor
        i32.add
        global.set $cons_cells_top
    )

    ;; Create copies of everything subsidiary to item above anchor
    ;; Return their new position minus the difference between anchor_2
    ;; and anchor.
    ;; Items below anchor are returned unchanged.
    ;;
    ;; This mechanism uses a sentinel (0x80_00_00_00) which cannot occur as a
    ;; normal item (since it would represent the last possible cons cell
    ;; assuming the full space was taken up) unless the program is almost
    ;; certainly about to crash from resource exhaustion anyway.
    ;; It uses this sentinel to mark a pointer at the original location of a
    ;; cons cell pointing to the new location of the cell.
    ;; This allows it to avoid making multiple distinct copies of shared cells
    ;; which is critical for meeting the required memory characteristics.
    (func $gc_copy
        (param $item i32)
        (param $anchor i32)
        (param $anchor_2 i32)
        (result i32)
        (local $copied_item i32)

        ;; Check if the item is above the anchor
        i32.const 0
        local.get $item
        i32.sub
        local.get $anchor
        i32.gt_s
        (if (result i32)
            (then
                ;; The item is above the anchor

                ;; Check if the head is the magic value 0x80_00_00_00 which
                ;; cannot occur normally
                local.get $item
                call $head
                i32.const 0x80_00_00_00
                i32.eq
                (if (result i32)
                    (then
                        ;; The head is the sentinel, this cell was already
                        ;; copied, load the cached copy
                        local.get $item
                        call $tail
                    )
                    (else
                        ;; Recursively copy the head
                        local.get $item
                        call $head
                        local.get $anchor
                        local.get $anchor_2
                        call $gc_copy

                        ;; Recursively copy the tail
                        local.get $item
                        call $tail
                        local.get $anchor
                        local.get $anchor_2
                        call $gc_copy

                        ;; Reconstruct the cons cell
                        call $cons

                        ;; Offset the cons cell to where it will go after being
                        ;; shifted down at the end of gc_collect
                        local.get $anchor_2
                        i32.add
                        local.get $anchor
                        i32.sub
                        local.set $copied_item

                        ;; Overwrite the original item with a magic sentinel
                        ;; indicating the item has already been copied and
                        ;; caching the copy.
                        ;; This step (and checking for these sentinels) is
                        ;; critical to ensure that multiple references to the
                        ;; same object don't become multiple separate copies
                        ;; and therefore that the garbage collector cannot
                        ;; inadvertently create more cons cells than there were
                        ;; to begin with.
                        i32.const 0
                        local.get $item
                        i32.sub
                        i32.const 0x80_00_00_00
                        i32.store (memory $cons_cells)

                        i32.const 4
                        local.get $item
                        i32.sub
                        local.get $copied_item
                        i32.store (memory $cons_cells)

                        local.get $copied_item
                    )
                )
            )
            (else
                ;; The item is below the anchor, do not adjust it
                local.get $item
            )
        )
    )
)
