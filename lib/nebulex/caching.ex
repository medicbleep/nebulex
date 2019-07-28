defmodule Nebulex.Caching do
  @moduledoc """
  DSL for cache usage patterns implementation.

  The DSL is composed of a set of macros for the implementation of caching
  patterns such as **Read-through**, **Write-through**, **Cache-as-SoR**, etc.

  ## Shared Options

  All of the caching macros below accept the following options:

    * `:cache` - Defines what cache to use (required). Raises `ArgumentError`
      if the option is not present.

    * `:key` - Defines the cache access key (optional). If this option
      is not present, a default key is generated by hashing a two-elements
      tuple; first element is the function's name and the second one the
      list of arguments (e.g: `:erlang.phash2({name, args})`).

    * `:opts` - Defines the cache options that will be passed as argument
      to the invoked cache function (optional).

  ## Example

  Suppose we are using `Ecto` and we want to define some caching functions in
  the context `MyApp.Accounts`.

      defmodule MyApp.Accounts do
        import Ecto.Query
        import Nebulex.Caching

        alias MyApp.Accounts.User
        alias MyApp.Cache
        alias MyApp.Repo

        defcacheable get_user!(id), cache: Cache, key: {User, id}, opts: [ttl: 3600] do
          Repo.get!(User, id)
        end

        defcacheable get_user_by!(clauses), cache: Cache, key: {User, clauses} do
          Repo.get_by!(User, clauses)
        end

        defcacheable users_by_segment(segment \\\\ "standard"), cache: Cache do
          query = from(q in User, where: q.segment == ^segment)
          Repo.all(query)
        end

        defupdatable update_user!(%User{} = user, attrs), cache: Cache, key: {User, user.id} do
          user
          |> User.changeset(attrs)
          |> Repo.update!()
        end

        defevict delete_user(%User{} = user),
          cache: Cache,
          keys: [{User, user.id}, {User, [username: user.username]}] do
          Repo.delete(user)
        end
      end
  """

  @doc """
  Defines a cacheable function with the given name `fun` and arguments `args`.

  The returned value by the code block is cached if it doesn't exist already
  in cache, otherwise, it is returned directly from cache and the code block
  is not executed.

  ## Options

  See the "Shared options" section at the module documentation.

  ## Examples

      defmodule MyApp.Example do
        import Nebulex.Caching
        alias MyApp.Cache

        defcacheable get_by_name(name, age), cache: Cache, key: name do
          # your logic (maybe the loader to retrieve the value from the SoR)
        end

        defcacheable get_by_age(age), cache: Cache, key: age, opts: [ttl: 3600] do
          # your logic (maybe the loader to retrieve the value from the SoR)
        end

        defcacheable all(query), cache: Cache do
          # your logic (maybe the loader to retrieve the value from the SoR)
        end
      end

  The **Read-through** pattern is supported by this macro. The loader to
  retrieve the value from the system-of-record (SoR) is your function's logic
  and the rest is provided by the macro under-the-hood.
  """
  defmacro defcacheable(fun, opts \\ [], do: block) do
    caching_action(:defcacheable, fun, opts, block)
  end

  @doc """
  Defines a function with cache eviction enabled on function completion
  (one, multiple or all values are removed on function completion).

  ## Options

    * `:keys` - Defines the set of keys meant to be evicted from cache
      on function completion. This option supersedes the `:key` option.
      Therefore, if `:keys` is set and is different than `[]`, then
      `:key` is ignored.

    * `:all_entries` - Defines if all entries must be removed on function
      completion. Defaults to `false`.

  See the "Shared options" section at the module documentation.

  ## Examples

      defmodule MyApp.Example do
        import Nebulex.Caching
        alias MyApp.Cache

        defevict evict(name), cache: Cache, key: name do
          # your logic (maybe write/delete data to the SoR)
        end

        defevict evict_many(name), cache: Cache, keys: [name, id] do
          # your logic (maybe write/delete data to the SoR)
        end

        defevict evict_all(name), cache: Cache, all_entries: true do
          # your logic (maybe write/delete data to the SoR)
        end
      end

  The **Write-through** pattern is supported by this macro. Your function
  provides the logic to write data to the system-of-record (SoR) and the rest
  is provided by the macro under-the-hood. But in contrast with `defupdatable`,
  when the data is written to the SoR, the key for that value is deleted from
  cache instead of updated.
  """
  defmacro defevict(fun, opts \\ [], do: block) do
    caching_action(:defevict, fun, opts, block)
  end

  @doc """
  Defines an updatable caching function.

  The content of the cache is updated without interfering the function
  execution. That is, the method would always be executed and the result
  cached.

  The difference between `defcacheable/3` and `defupdatable/3` is that
  `defcacheable/3` will skip running the function (if the key exists in cache),
  whereas `defupdatable/3` will actually run the function and then put the
  result in the cache.

  ## Options

  See the "Shared options" section at the module documentation.

  ## Examples

      defmodule MyApp.Example do
        import Nebulex.Caching
        alias MyApp.Cache

        defupdatable update(name), cache: Cache, key: name do
          # your logic (maybe write data to the SoR)
        end

        defupdatable update_with_ttl(name), cache: Cache, opts: [ttl: 3600] do
          # your logic (maybe write data to the SoR)
        end
      end

  The **Write-through** pattern is supported by this macro. Your function
  provides the logic to write data to the system-of-record (SoR) and the rest
  is provided by the macro under-the-hood.
  """
  defmacro defupdatable(fun, opts \\ [], do: block) do
    caching_action(:defupdatable, fun, opts, block)
  end

  ## Hepers

  @doc false
  def evict(cache, _key, _keys, true) do
    cache.flush()
  end

  def evict(cache, _key, [_ | _] = keys, _all_entries?) do
    Enum.each(keys, &cache.delete(&1))
  end

  def evict(cache, key, _keys, _all_entries?) do
    cache.delete(key)
  end

  ## Private Functions

  defp caching_action(action, fun, opts, block) do
    cache =
      Keyword.get(opts, :cache) || raise ArgumentError, "expected cache: to be given as argument"

    {name, args} =
      case Macro.decompose_call(fun) do
        {_, _} = pair -> pair
        _ -> raise ArgumentError, "invalid syntax in #{action} #{Macro.to_string(fun)}"
      end

    as_args = build_as_args(args)
    key_var = Keyword.get(opts, :key)
    keys_var = Keyword.get(opts, :keys)
    opts_var = Keyword.get(opts, :opts, [])
    action_logic = action_logic(action, block, opts)

    quote do
      def unquote(name)(unquote_splicing(args)) do
        cache = unquote(cache)
        key = unquote(key_var) || :erlang.phash2({unquote(name), unquote(as_args)})
        keys = unquote(keys_var)
        opts = unquote(opts_var)

        unquote(action_logic)
      end
    end
  end

  defp action_logic(:defcacheable, block, _opts) do
    quote do
      if value = cache.get(key, opts) do
        value
      else
        value = unquote(block)
        cache.set(key, value, opts)
      end
    end
  end

  defp action_logic(:defevict, block, opts) do
    all_entries? = Keyword.get(opts, :all_entries, false)

    quote do
      unquote(__MODULE__).evict(cache, key, keys, unquote(all_entries?))
      unquote(block)
    end
  end

  defp action_logic(:defupdatable, block, _opts) do
    quote do
      value = unquote(block)
      cache.set(key, value, opts)
    end
  end

  defp build_as_args(args) do
    for arg <- args, do: build_as_arg(arg)
  end

  defp build_as_arg({:\\, _, [arg, _default_arg]}), do: build_as_arg(arg)
  defp build_as_arg(arg), do: arg
end