export @esc, isexpr, isline, rmlines, unblock, block, inexpr, namify, isdef,
  longdef, shortdef, @expand, makeif, prettify, splitdef, splitarg

assoc!(d, k, v) = (d[k] = v; d)

"""
    @esc x y

is the same as

    x = esc(x)
    y = esc(y)
"""
macro esc(xs...)
  :($([:($x = esc($x)) for x in map(esc, xs)]...);)
end

"""
    @q [expression]

Like the `quote` keyword but doesn't insert line numbers from the construction
site. e.g. compare `@q begin end` with `quote end`. Line numbers of interpolated
expressions are preserverd.
"""
macro q(ex)
  Expr(:quote, striplines(ex))
end

"""
    isexpr(x, ts...)

Convenient way to test the type of a Julia expression.
Expression heads and types are supported, so for example
you can call

    isexpr(expr, String, :string)

to pick up on all string-like expressions.
"""
isexpr(x::Expr) = true
isexpr(x) = false
isexpr(x::Expr, ts...) = x.head in ts
isexpr(x, ts...) = any(T->isa(T, Type) && isa(x, T), ts)

isline(ex) = isexpr(ex, :line) || isa(ex, LineNumberNode)

"""
    rmlines(x)

Remove the line nodes from a block or array of expressions.

Compare `quote end` vs `rmlines(quote end)`
"""
rmlines(x) = x
rmlines(x::Expr) = Expr(x.head, filter(x->!isline(x), x.args)...)

striplines(ex) = prewalk(rmlines, ex)

"""
    unblock(expr)

Remove outer `begin` blocks from an expression, if the block is
redundant (i.e. contains only a single expression).
"""
function unblock(ex)
  isexpr(ex, :block) || return ex
  exs = rmlines(ex).args
  length(exs) == 1 || return ex
  return unblock(exs[1])
end

block(ex) = isexpr(ex, :block) ? ex : :($ex;)

"""
An easy way to get pull the (function/type) name out of
expressions like `foo{T}` or `Bar{T} <: Vector{T}`.
"""
namify(s::Symbol) = s
namify(ex::Expr) = namify(ex.args[1])

walk(x, inner, outer) = outer(x)
walk(x::Expr, inner, outer) = outer(Expr(x.head, map(inner, x.args)...))

"""
    postwalk(f, expr)

Applies `f` to each node in the given expression tree, returning the result.
`f` sees expressions *after* they have been transformed by the walk. See also
`prewalk`.
"""
postwalk(f, x) = walk(x, x -> postwalk(f, x), f)

"""
    prewalk(f, expr)

Applies `f` to each node in the given expression tree, returning the result.
`f` sees expressions *before* they have been transformed by the walk, and the
walk will be applied to whatever `f` returns.

This makes `prewalk` somewhat prone to infinite loops; you probably want to try
`postwalk` first.
"""
prewalk(f, x)  = walk(f(x), x -> prewalk(f, x), identity)

replace(ex, s, s′) = prewalk(x -> x == s ? s′ : x, ex)

"""
    inexpr(expr, x)

Simple expression match; will return `true` if the expression `x` can be found
inside `expr`.

    inexpr(:(2+2), 2) == true
"""
function inexpr(ex, x)
  result = false
  MacroTools.postwalk(ex) do y
    y == x && (result = true)
  end
  return result
end

global const animals = split(readstring(joinpath(dirname(@__FILE__), "..", "animals.txt")))

isgensym(s::Symbol) = contains(string(s), "#")
isgensym(s) = false

"""
    alias_gensyms(expr)

Replaces gensyms with animal names. This makes gensym'd code far easier to
follow.
"""
function alias_gensyms(ex)
  syms = Dict{Symbol, Symbol}()
  s(x) = get!(syms, x, lowercase(rand(filter(s->!(s in values(syms)), animals))))
  prewalk(ex) do x
    isgensym(x) ? s(x) : x
  end
end

"""
More convenient macro expansion, e.g.

    @expand @time foo()
"""
macro expand(ex)
    :(alias_gensyms(macroexpand($(@static isdefined(Base, Symbol("@__MODULE__")) ?
                                  __module__ : current_module()), $(ex,)[1])))
end

"Test for function definition expressions."
isdef(ex) = ismatch(or_(:(function _(__) _ end),
                        :(f_(__) = _)),
                    ex)

function longdef1(ex)
  @match ex begin
    (f_(args__) = body_) => @q function $f($(args...)) $body end
    (f_(args__)::rtype_ = body_) => @q function $f($(args...))::$rtype $body end
    ((args__,) -> body_) => @q function ($(args...),) $body end
    (arg_ -> body_) => @q function ($arg,) $body end
    _ => ex
  end
end
longdef(ex) = prewalk(longdef1, ex)

function shortdef1(ex)
  @match ex begin
    function f_(args__) body_ end => @q $f($(args...)) = $body
    function f_(args__)::rtype_ body_ end => @q $f($(args...))::$rtype = $body
    function (args__,) body_ end => @q ($(args...),) -> $body
    ((args__,) -> body_) => ex
    (arg_ -> body_) => @q ($arg,) -> $body
    _ => ex
  end
end
shortdef(ex) = prewalk(shortdef1, ex)

""" `splitkwargs(x)` splits an argument list into positional and keyword args.
Returns `(args::Vector, kwargs::Vector)` """
function splitkwargs(args)
    if !isempty(args) && isa(args[1], Expr) && args[1].head == :parameters
        return args[2:end], args[1].args
    else
        return args, []
    end    
end

"""    splitdef(fdef)

Match a function definition such as

```julia
function fname(args; kwargs)::return_type
   body
end
```

and returns a `Dict` with keys `:name`, `:args`, `:kwargs` and `:body`. If there is
a return type in the definition, `:rtype` will be in the dictionary, too. """
function splitdef(fdef)
    mkdict(fname, args, kwargs, body, other_pairs...) =
        Dict(:name=>fname, :args=>args, :kwargs=>kwargs, :body=>body, other_pairs...)
    error_msg = "Not a function definition: $fdef"
    @assert(@capture(longdef1(fdef),
                     function ((fname_(allargs__)) | (fname_(allargs__)::rtype_))
                     body_ end),
            error_msg)
    args, kwargs = splitkwargs(allargs)
    di = Dict(:name=>fname, :args=>args, :kwargs=>kwargs, :body=>body)
    if rtype != nothing
        di[:rtype] = rtype
    end
    di
end


""" `splitarg(arg)` matches function arguments (whether from a definition or a function
call) such as `x::Int=2` and returns `(arg_name, arg_type, default)`. `default` is
`nothing` when there is none. For example:

```julia
> map(splitarg, (:(f(a=2, x::Int=nothing, y))).args[2:end])
3-element Array{Tuple{Symbol,Symbol,Any},1}:
 (:a, :Any, 2)       
 (:x, :Int, :nothing)
 (:y, :Any, nothing)
```
"""
function splitarg(arg_expr)
    split_var(arg) =
        @match arg begin
            ::T_ => (nothing, T)
            name_::T_ => (name, T)
            x_ => (arg, :Any)
        end
    if @capture(arg_expr, arg_ = default_)
        @assert default !== nothing "splitarg cannot handle `nothing` as a default. Use a quoted `nothing` if possible. (MacroTools#35)"
        return (split_var(arg)..., default)
    else
        return (split_var(arg_expr)..., nothing)
    end
end


function flatten1(ex)
  isexpr(ex, :block) || return ex
  #ex′ = :(;)
  ex′ = Expr(:block)
  for x in ex.args
    isexpr(x, :block) ? append!(ex′.args, x.args) : push!(ex′.args, x)
  end
  return ex′
end

flatten(ex) = postwalk(flatten1, ex)

function makeif(clauses, els = nothing)
  foldr((c, ex)->:($(c[1]) ? $(c[2]) : $ex), els, clauses)
end

unresolve1(x) = x
unresolve1(f::Function) = methods(f).mt.name

unresolve(ex::Expr) = prewalk(unresolve1, ex)

function resyntax(ex)
  prewalk(ex) do x
    @match x begin
      setfield!(x_, :f_, x_.f_ + v_) => :($x.$f += $v)
      setfield!(x_, :f_, v_) => :($x.$f = $v)
      getindex(x_, i__) => :($x[$(i...)])
      tuple(xs__) => :($(xs...),)
      ctranspose(x_) => :($x')
      transpose(x_) => :($x.')
      _ => x
    end
  end
end

"""
    prettify(ex)

Makes generated code generaly nicer to look at.
"""
prettify(ex; lines = false) =
  ex |> flatten |> unresolve |> resyntax |> alias_gensyms |> (lines ? identity : striplines)
