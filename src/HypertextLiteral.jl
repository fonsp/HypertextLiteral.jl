"""
    HypertextLiteral

This library provides for a `@htl()` macro and a `htl` string literal,
both implementing interpolation that is aware of hypertext escape
context. The `@htl` macro has the advantage of using Julia's native
string parsing, so that it can handle arbitrarily deep nesting. However,
it is a more verbose than the `htl` string literal and doesn't permit
interpolated string literals. Conversely, the `htl` string literal,
`@htl_str`, uses custom parsing letting it handle string literal
escaping, however, it can only be used two levels deep (using three
quotes for the outer nesting, and a single double quote for the inner).

Both macros use the same conversion, `HypertextLiteral.htl_convert`,
which calls `HypertextLiteral.htl_escape` to perform context sensitive
hypertext escaping. User defined methods could be added to `htl_escape`
so that this library could be made aware of custom data types.
"""
module HypertextLiteral

export @htl_str, @htl

"""
    @htl string-expression

Create a `HTML{String}` with string interpolation (`\$`) that uses
context-sensitive hypertext escaping. Escaping of interpolated results
is performed by `htl_escape`. Rather than escaping interpolated string
literals, e.g. `\$("Strunk & White")`, they are treated as errors since
they cannot be reliably detected (see Julia issue #38501).
"""
macro htl(expr)
    if expr isa String
        return htl_convert([expr])
    end
    # Find cases where we may have an interpolated string literal and
    # raise an exception (till Julia issue #38501 is addressed)
    @assert expr isa Expr
    @assert expr.head == :string
    if length(expr.args) == 1 && expr.args[1] isa String
        throw("interpolated string literals are not supported")
    end
    for idx in 2:length(expr.args)
        if expr.args[idx] isa String && expr.args[idx-1] isa String
            throw("interpolated string literals are not supported")
        end
    end
    return htl_convert(expr.args)
end

"""
    @htl_str -> Base.Docs.HTML{String}

Create a `HTML{String}` with string interpolation (`\$`) that uses
context-sensitive hypertext escaping. Escaping of interpolated results
is performed by `htl_escape`. Escape sequences should work identically
to Julia strings, except in cases where a slash immediately precedes the
double quote (see `@raw_str` and Julia issue #22926 for details).
"""
macro htl_str(expr::String)
    # This implementation emulates Julia's string interpolation behavior
    # as close as possible to produce an expression vector similar to
    # what would be produced by the `@htl` macro. Unlike most text
    # literals, we unescape content here. This logic also directly
    # handles interpolated literals, with contextual escaping.
    args = Any[]
    vstr = String[]
    start = idx = 1
    strlen = length(expr)
    escaped = false
    while idx <= strlen
        c = expr[idx]
        if c == '\\'
            escaped = !escaped
            idx += 1
            continue
        end
        if c != '$'
            escaped = false
            idx += 1
            continue
        end
        finish = idx - (escaped ? 2 : 1)
        push!(vstr, unescape_string(SubString(expr, start:finish)))
        start = idx += 1
        if escaped
            escaped = false
            push!(vstr, "\$")
            continue
        end
        (nest, idx) = Meta.parse(expr, start; greedy=false)
        if nest == nothing
            throw("invalid interpolation syntax")
        end
        start = idx
        if nest isa String
            # this is an interpolated string literal
            nest = Expr(:string, nest)
        end
        if length(vstr) > 0
            push!(args, join(vstr))
            empty!(vstr)
        end
        push!(args, nest)
    end
    if start <= strlen
        push!(vstr, unescape_string(SubString(expr, start:strlen)))
    end
    if length(vstr) > 0
        push!(args, join(vstr))
        empty!(vstr)
    end
    return htl_convert(args)
end

"""
    htl_convert(exprs[])::Expr

Transform a vector consisting of hypertext fragments and interpolated
expressions (that are to be escaped) into an expression with
context-sensitive escaping. The fragments are typically passed along
as-is, however, they could be transformed and/or normalized. This logic
inlines the splat operator.
"""
function htl_convert(exprs)::Expr
    quote
        local args = Any[]
        $(map(exprs) do expr
            if expr isa String
                quote
                    push!(args, $(expr))
                end
            elseif expr isa Expr && expr.head == :...
                quote
                    for part in $(esc(expr.args[1]))
                        push!(args, htl_escape(part))
                    end
                end
            else
                quote
                    push!(args, htl_escape($(esc(expr))))
                end
            end
        end...)
        HTML(string(args...))
    end
end

"""
    htl_escape(context::Symbol, obj)::String

For a given HTML lexical context and an arbitrary Julia object, return
a `String` value that is properly escaped. Splatting interpolation
concatenates these escaped values. This fallback implements:
`HTML{String}` objects are assumed to be properly escaped, and hence
its content is returned; `Vector{HTML{String}}` are concatenated; any
`Number` is converted to a string using `string()`; and `AbstractString`
objects are escaped according to context.

There are several escaping contexts. The `:content` scope is for HTML
content, at a minimum, the ampersand (`&`) and less-than (`<`)
characters must be escaped.
"""
function htl_escape(obj)::String
    if obj isa HTML{String}
        return obj.content
    elseif obj isa Vector{HTML{String}}
        return join([part.content for part in obj])
    elseif obj isa AbstractString
        return replace(replace(obj, "&" => "&amp;"), "<" => "&lt;")
    elseif obj isa Number
        return string(obj)
    else
        extra = ""
        if obj isa AbstractVector
            extra = ("\nPerhaps use splatting? e.g. " *
                     "htl\"\$([x for x in 1:3]...)\"")
        end
        throw(DomainError(obj,
         "Type $(typeof(obj)) lacks an `htl_escape` specialization.$(extra)"))
    end
end

#
# Code imported from Michiel Dral
#

struct Escaped value end

abstract type InterpolatedValue end

function Base.show(io::IO, mime::MIME"text/html", x::InterpolatedValue)
    throw("""
        show text/html should be override for InterpolatedValue.
        Got a $(typeof(x)) without html show overload.
    """)
end

struct AttributeValue <: InterpolatedValue
    name::String
    value
end

struct Javascript
    content
end

Base.show(io::IO, mime::MIME"application/javascript", js::Javascript) =
    print(io, js.content)

struct StateData <: InterpolatedValue value end
struct AttributeUnquoted <: InterpolatedValue value end
struct AttributeDoubleQuoted <: InterpolatedValue value end
struct AttributeSingleQuoted <: InterpolatedValue value end
struct BeforeAttributeName <: InterpolatedValue value end

function Base.show(io::IO, mime::MIME"text/html", x::BeforeAttributeName)
    if x.value isa Dict
        for (key, value) in pairs(x.value)
            show(io, mime, AttributeValue(name=key, value=value))
            print(io, " ")
        end
    elseif x.value isa Pair
        show(io, mime, AttributeValue(name=x.value.first, value=x.value.second))
        print(io, " ")
    else
        throw("invalid binding #2 $(typeof(x.value)) $(x.value)")
    end
end

struct InterpolateArray
    arr::Array
end

function show_interpolation(arr::InterpolateArray)
    for value in arr.arr
        if value isa InterpolatedValue
            return sprint(dump, value) |> Text
        end
    end
end

const HtlString = InterpolateArray

function Base.:*(arr::InterpolateArray, string::String)
    if isempty(arr.arr)
        InterpolateArray([string])
    elseif typeof(last(arr.arr)) == String
        InterpolateArray([
            arr.arr[begin:end-1]...,
            last(arr.arr) * string
        ])
    else
        InterpolateArray([arr.arr..., string])
    end
end

function Base.:*(arr::InterpolateArray, something::InterpolatedValue)
    InterpolateArray([arr.arr..., something])
end

function Base.length(arr::InterpolateArray)
    sum(map(arr.arr) do x
        if x isa AbstractString
            length(x)
        else
            1
        end
    end)
end

function Base.getindex(arr::InterpolateArray, range::UnitRange)
    InterpolateArray([
        arr.arr[begin:end-1]...,
        arr.arr[end][range]
    ])
end

function Base.show(io::IO, mime::MIME"text/html", array::InterpolateArray)
    for item in array.arr
        if item isa AbstractString
            print(io, item)
        else
            show(io, mime, item)
        end
    end
end

begin
    const CODE_TAB = 9
    const CODE_LF = 10
    const CODE_FF = 12
    const CODE_CR = 13
    const CODE_SPACE = 32
    const CODE_UPPER_A = 65
    const CODE_UPPER_Z = 90
    const CODE_LOWER_A = 97
    const CODE_LOWER_Z = 122
    const CODE_LT = 60
    const CODE_GT = 62
    const CODE_SLASH = 47
    const CODE_DASH = 45
    const CODE_BANG = 33
    const CODE_EQ = 61
    const CODE_DQUOTE = 34
    const CODE_SQUOTE = 39
    const CODE_QUESTION = 63
end

@enum HtlParserState STATE_DATA STATE_TAG_OPEN STATE_END_TAG_OPEN STATE_TAG_NAME STATE_BOGUS_COMMENT STATE_BEFORE_ATTRIBUTE_NAME STATE_AFTER_ATTRIBUTE_NAME STATE_ATTRIBUTE_NAME STATE_BEFORE_ATTRIBUTE_VALUE STATE_ATTRIBUTE_VALUE_DOUBLE_QUOTED STATE_ATTRIBUTE_VALUE_SINGLE_QUOTED STATE_ATTRIBUTE_VALUE_UNQUOTED STATE_AFTER_ATTRIBUTE_VALUE_QUOTED STATE_SELF_CLOSING_START_TAG STATE_COMMENT_START STATE_COMMENT_START_DASH STATE_COMMENT STATE_COMMENT_LESS_THAN_SIGN STATE_COMMENT_LESS_THAN_SIGN_BANG STATE_COMMENT_LESS_THAN_SIGN_BANG_DASH STATE_COMMENT_LESS_THAN_SIGN_BANG_DASH_DASH STATE_COMMENT_END_DASH STATE_COMMENT_END STATE_COMMENT_END_BANG STATE_MARKUP_DECLARATION_OPEN

function entity(str::AbstractString)
    @assert length(str) == 1
    entity(str[1])
end

entity(character::Char) = "&#$(Int(character));"

function Base.show(io::IO, mime::MIME"text/html", child::StateData)
    if showable(MIME("text/html"), child.value)
        show(io, mime, child.value)
    elseif child.value isa AbstractArray{HtlString}
        for subchild in child.value
            show(io, mime, subchild)
        end
    else
        print(io, replace(string(child.value), r"[<&]" => entity))
    end
end

function Base.show(io::IO, ::MIME"text/html", x::AttributeUnquoted)
    print(io, replace(x.value, r"[\s>&]" => entity))
end

function Base.show(io::IO, ::MIME"text/html", x::AttributeDoubleQuoted)
    print(io, replace(x.value, r"[\"&]" => entity))
end

function Base.show(io::IO, ::MIME"text/html", x::AttributeSingleQuoted)
    print(io, replace(x.value, r"['&]" => entity))
end

function isAsciiAlphaCode(code::Int)::Bool
  return (
        CODE_UPPER_A <= code
        && code <= CODE_UPPER_Z
    ) || (
        CODE_LOWER_A <= code
        && code <= CODE_LOWER_Z
    )
end

function isSpaceCode(code)
  return ( code === CODE_TAB
        || code === CODE_LF
        || code === CODE_FF
        || code === CODE_SPACE
        || code === CODE_CR
    ) # normalize newlines
end

function hypertext(args)
    state = STATE_DATA
    string = InterpolateArray([])
    nameStart = 0
    nameEnd = 0

    for j in 1:length(args)
        if args[j] isa Escaped
            value = args[j].value

            if state == STATE_DATA
                string *= StateData(value)

            elseif state == STATE_BEFORE_ATTRIBUTE_VALUE
                state = STATE_ATTRIBUTE_VALUE_UNQUOTED

                name = args[j - 1][nameStart:nameEnd]
                prefixlength = length(string) - nameStart

                string = InterpolateArray([
                    string.arr[begin:end-1]...,
                    string.arr[end][begin:nameStart - 1]
                ])


                # string = string[1:(nameStart - length(strings[j - 1]))]
                string *= AttributeValue(name, value)

            elseif state == STATE_ATTRIBUTE_VALUE_UNQUOTED
                string *= AttributeUnquoted(value)

            elseif state == STATE_ATTRIBUTE_VALUE_SINGLE_QUOTED
                string *= AttributeSingleQuoted(value)

            elseif state == STATE_ATTRIBUTE_VALUE_DOUBLE_QUOTED
                string *= AttributeDoubleQuoted(value)

            elseif state == STATE_BEFORE_ATTRIBUTE_NAME
                string *= BeforeAttributeName(value)

            elseif state == STATE_COMMENT || true
                throw("invalid binding #1 $(state)")
            end
        else
            input = args[j]
            inputlength = length(input)
            i = 1
            while i <= inputlength
                code = Int(input[i])

                if state == STATE_DATA
                    if code === CODE_LT
                        state = STATE_TAG_OPEN
                    end

                elseif state == STATE_TAG_OPEN
                    if code === CODE_BANG
                        state = STATE_MARKUP_DECLARATION_OPEN
                    elseif code === CODE_SLASH
                        state = STATE_END_TAG_OPEN
                    elseif isAsciiAlphaCode(code)
                        state = STATE_TAG_NAME
                        i -= 1
                    elseif code === CODE_QUESTION
                        state = STATE_BOGUS_COMMENT
                        i -= 1
                    else
                        state = STATE_DATA
                        i -= 1
                    end

                elseif state == STATE_END_TAG_OPEN
                    if isAsciiAlphaCode(code)
                        state = STATE_TAG_NAME
                        i -= 1
                    elseif code === CODE_GT
                        state = STATE_DATA
                    else
                        state = STATE_BOGUS_COMMENT
                        i -= 1
                    end

                elseif state == STATE_TAG_NAME
                    if isSpaceCode(code)
                        state = STATE_BEFORE_ATTRIBUTE_NAME
                    elseif code === CODE_SLASH
                        state = STATE_SELF_CLOSING_START_TAG
                    elseif code === CODE_GT
                        state = STATE_DATA
                    end

                elseif state == STATE_BEFORE_ATTRIBUTE_NAME
                    if isSpaceCode(code)
                        nothing
                    elseif code === CODE_SLASH || code === CODE_GT
                        state = STATE_AFTER_ATTRIBUTE_NAME
                        i -= 1
                    elseif code === CODE_EQ
                        state = STATE_ATTRIBUTE_NAME
                        nameStart = i + 1
                        nameEnd = nothing
                    else
                        state = STATE_ATTRIBUTE_NAME
                        i -= 1
                        nameStart = i + 1
                        nameEnd = nothing
                    end

                elseif state == STATE_ATTRIBUTE_NAME
                    if isSpaceCode(code) || code === CODE_SLASH || code === CODE_GT
                        state = STATE_AFTER_ATTRIBUTE_NAME
                        nameEnd = i - 1
                        i -= 1
                    elseif code === CODE_EQ
                        state = STATE_BEFORE_ATTRIBUTE_VALUE
                        nameEnd = i - 1
                    end

                elseif state == STATE_AFTER_ATTRIBUTE_NAME
                    if isSpaceCode(code)
                        # ignore
                    elseif code === CODE_SLASH
                        state = STATE_SELF_CLOSING_START_TAG
                    elseif code === CODE_EQ
                        state = STATE_BEFORE_ATTRIBUTE_VALUE
                    elseif code === CODE_GT
                        state = STATE_DATA
                    else
                        state = STATE_ATTRIBUTE_NAME
                        i -= 1
                        nameStart = i + 1
                        nameEnd = nothing
                    end

                elseif state == STATE_BEFORE_ATTRIBUTE_VALUE
                    if isSpaceCode(code)
                        # continue
                    elseif code === CODE_DQUOTE
                        state = STATE_ATTRIBUTE_VALUE_DOUBLE_QUOTED
                    elseif code === CODE_SQUOTE
                        state = STATE_ATTRIBUTE_VALUE_SINGLE_QUOTED
                    elseif code === CODE_GT
                        state = STATE_DATA
                    else
                        state = STATE_ATTRIBUTE_VALUE_UNQUOTED
                        i -= 1
                    end

                elseif state == STATE_ATTRIBUTE_VALUE_DOUBLE_QUOTED
                    if code === CODE_DQUOTE
                        state = STATE_AFTER_ATTRIBUTE_VALUE_QUOTED
                    end

                elseif state == STATE_ATTRIBUTE_VALUE_SINGLE_QUOTED
                    if code === CODE_SQUOTE
                        state = STATE_AFTER_ATTRIBUTE_VALUE_QUOTED
                    end

                elseif state == STATE_ATTRIBUTE_VALUE_UNQUOTED
                    if isSpaceCode(code)
                        state = STATE_BEFORE_ATTRIBUTE_NAME
                    elseif code === CODE_GT
                        state = STATE_DATA
                    end

                elseif state == STATE_AFTER_ATTRIBUTE_VALUE_QUOTED
                    if isSpaceCode(code)
                        state = STATE_BEFORE_ATTRIBUTE_NAME
                    elseif code === CODE_SLASH
                        state = STATE_SELF_CLOSING_START_TAG
                    elseif code === CODE_GT
                        state = STATE_DATA
                    else
                        state = STATE_BEFORE_ATTRIBUTE_NAME
                        i -= 1
                    end

                elseif state == STATE_SELF_CLOSING_START_TAG
                    if code === CODE_GT
                        state = STATE_DATA
                    else
                        state = STATE_BEFORE_ATTRIBUTE_NAME
                        i -= 1
                    end

                elseif state == STATE_BOGUS_COMMENT
                    if code === CODE_GT
                        state = STATE_DATA
                    end

                elseif state == STATE_COMMENT_START
                    if code === CODE_DASH
                        state = STATE_COMMENT_START_DASH
                    elseif code === CODE_GT
                        state = STATE_DATA
                    else
                        state = STATE_COMMENT
                        i -= 1
                    end

                elseif state == STATE_COMMENT_START_DASH
                    if code === CODE_DASH
                        state = STATE_COMMENT_END
                    elseif code === CODE_GT
                        state = STATE_DATA
                    else
                        state = STATE_COMMENT
                        i -= 1
                    end

                elseif state == STATE_COMMENT
                    if code === CODE_LT
                        state = STATE_COMMENT_LESS_THAN_SIGN
                    elseif code === CODE_DASH
                        state = STATE_COMMENT_END_DASH
                    end

                elseif state == STATE_COMMENT_LESS_THAN_SIGN
                    if code === CODE_BANG
                        state = STATE_COMMENT_LESS_THAN_SIGN_BANG
                    elseif code !== CODE_LT
                        state = STATE_COMMENT
                        i -= 1
                    end

                elseif state == STATE_COMMENT_LESS_THAN_SIGN_BANG
                    if code === CODE_DASH
                        state = STATE_COMMENT_LESS_THAN_SIGN_BANG_DASH
                    else
                        state = STATE_COMMENT
                        i -= 1
                    end

                elseif state == STATE_COMMENT_LESS_THAN_SIGN_BANG_DASH
                    if code === CODE_DASH
                        state = STATE_COMMENT_LESS_THAN_SIGN_BANG_DASH_DASH
                    else
                        state = STATE_COMMENT_END
                        i -= 1
                    end

                elseif state == STATE_COMMENT_LESS_THAN_SIGN_BANG_DASH_DASH
                    state = STATE_COMMENT_END
                        i -= 1

                elseif state == STATE_COMMENT_END_DASH
                    if code === CODE_DASH
                        state = STATE_COMMENT_END
                    else
                        state = STATE_COMMENT
                        i -= 1
                    end

                elseif state == STATE_COMMENT_END
                    if code === CODE_GT
                        state = STATE_DATA
                    elseif code === CODE_BANG
                        state = STATE_COMMENT_END_BANG
                    elseif code !== CODE_DASH
                        state = STATE_COMMENT
                        i -= 1
                    end

                elseif state == STATE_COMMENT_END_BANG
                    if code === CODE_DASH
                        state = STATE_COMMENT_END_DASH
                    elseif code === CODE_GT
                        state = STATE_DATA
                    else
                        state = STATE_COMMENT
                        i -= 1
                    end

                elseif state == STATE_MARKUP_DECLARATION_OPEN
                    if code === CODE_DASH && Int(input[i + 1]) == CODE_DASH
                        state = STATE_COMMENT_START
                        i += 1
                    else # Note: CDATA and DOCTYPE unsupported!
                        state = STATE_BOGUS_COMMENT
                        i -= 1
                    end
                else
                    state = nothing
                end

                i = i + 1
            end
        string *= input
        end

    end

    return string
end

function isObjectLiteral(value)
    typeof(value) == Dict
end

function camelcase_to_dashes(str::String)
    # eg :fontSize => "font-size"
    replace(str, r"[A-Z]" => (x -> "-$(lowercase(x))"))
end

css_value(key, value) = string(value)
css_value(key, value::Real) = "$(value)px"
css_value(key, value::AbstractString) = value

css_key(key::Symbol) = camelcase_to_dashes(string(key))
css_key(key::String) = key

function render_inline_css(styles::Dict)
    result = ""
    for (key, value) in pairs(styles)
        result *= render_inline_css(key => value)
    end
    result
end

function render_inline_css(style::Tuple{Pair})
    result = ""
    for (key, value) in styles
        result *= render_inline_css(key => value)
    end
    result
end

function render_inline_css((key, value)::Pair)
    "$(css_key(key)): $(css_value(key, value));"
end

function Base.show(io::IO, mime::MIME"text/html", attribute::AttributeValue)
    value = attribute.value
    result = if value === nothing || value == false
        ""
    else
        righthandside = if value === true
            "\"\""
        elseif (
            attribute.name === "style" &&
            hasmethod(render_inline_css, Tuple{typeof(attribute.value)})
        )
            render_inline_css(attribute.value)
        elseif showable(MIME("application/javascript"), attribute.value)
            sprint(show, MIME("application/javascript"), attribute.value)
        else
            string(attribute.value)
        end
        escaped = replace(righthandside, r"^['\"]|[\s>&]" => entity)
        "$(attribute.name)=$(escaped)"
    end

    print(io, result)
end

end
