#
# MIT License
#
# Copyright (c) 2021 Matthew Evans
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#

defmodule EZTracer do

  def main(args \\ []) do
    try do
      args
      |> OptionParser.parse(
        strict: [
          node: :string,
          cookie: :string,
          processes: :string,
          msgs: :string,
          type: :string,
          mf: :string,
          sol: :boolean,
          sos: :boolean,
          timestamp: :boolean,
          noargs: :boolean,
          help: :boolean
        ]
      )
      |> EZTracerInternal.start_tracing()
    rescue
      e in ArgumentError -> EZTracerInternal.error(e.message)
      e in FunctionClauseError -> IO.puts("error: " <> e.message)
      e -> IO.puts("error #{inspect(e)}")
    end
  end
end


defmodule EZTracerInternal do

  @maximum_events "100"
  @pops [sos: true, sol: true, timestamp: true]

  def error(error) do
    IO.puts(~s(#{inspect error}\n))
    help()
  end

  def external_cleanup(monitor_node, pids) do
    :erlang.process_flag(:trap_exit, :true)
    :erlang.monitor_node(monitor_node, true)
    do_external_cleanup(monitor_node, pids)
  end

  def start_tracing({args, _, _}) do
    if Keyword.get(args, :help) do
      help()
    end

    target_node = EZTracerConnect.connect(args)

    remote_module_load(target_node)

    :gen_event.swap_handler(
      :erl_signal_server,
      {:erl_signal_handler, []},
      {SignalHandler, [self()]}
    )

    processes = args[:processes]

    get_remote_pids(target_node, processes) |> do_start_tracing(target_node, args) |> cleanup(target_node)
  end

  defp do_external_cleanup(monitor_node, pids) do
    receive do
      {:nodedown, ^monitor_node} ->
        for pid <- pids, do: :dbg.p(pid, :clear)
        :dbg.stop_clear()
        :erlang.trace_pattern({:_, :_, :_}, :false, [:local])
        :erlang.trace_pattern({:_, :_, :_}, :false, [:global])
      _ ->
        external_cleanup(monitor_node, pids)
    end
  end

  defp cleanup({pids, reason}, node) do
    :rpc.call(node, :code, :purge, [__MODULE__])
    :rpc.call(node, :code, :delete, [__MODULE__])
    for pid <- pids, do: :dbg.p(pid, :clear)
    :dbg.stop_clear()
    IO.puts("eztracer has terminated normally (" <> inspect(reason) <> ")")
  end

  defp remote_module_load(node) do
    {mod, bin, _file} = :code.get_object_code(__MODULE__)
    :rpc.call(node, :code, :load_binary, [mod, '/tmp/tracer.beam', bin])
  end

  defp get_remote_pids(node, processes) do
    String.replace(processes, [" ", "[", "]"], "")
    |> String.replace("<", "\"<")
    |> String.replace(">", ">\"")
    |> String.split(",")
    |> Enum.map(fn item -> make_possible_atom(item) <> "," end)
    |> Enum.into("")
    |> String.trim_trailing(",")
    |> eval_string()
    |> Enum.map(fn p -> get_remote_pid(node, p) end)
    |> List.flatten()
  end

  defp get_remote_pid(node, name) do
    with {:ok, result} <- get_ranch_process_id(node, name, nil),
         {:ok, result} <- get_regular_process_id(node, name, result),
         {:ok, result} <- get_registered_name_process_id(node, name, result),
         {:ok, result} <- get_pg2_name_process_id(node, name, result),
         {:ok, result} <- finalize_pid_search(result)
    do
       result
    else
      _ -> raise(ArgumentError, "error resolving #{inspect name}")
    end
  end

  defp finalize_pid_search({:ok, result}), do:
    {:ok, result}

  defp finalize_pid_search(result), do:
    {:error, result}

  def get_ranch_process_id(_node, _name, {:ok, last_result}), do:
    {:ok, {:ok, last_result}}

  def get_ranch_process_id(node, :ranch, _last_result), do:
    get_pid_rpc(node, :ets, :select, [:ranch_server, [{{{:conns_sup,:_}, :'$1'}, [], [:'$1']}]])

  def get_ranch_process_id(_node, _name, _last_result), do:
    {:ok, :error}

  def get_regular_process_id(_node, _name, {:ok, last_result}), do:
    {:ok, {:ok, last_result}}

  def get_regular_process_id(node, name, _last_result) when is_binary(name), do:
    get_pid_rpc(node, :erlang, :list_to_pid, [to_charlist(name)])

  def get_regular_process_id(_node, _name, _last_result), do:
    {:ok, :error}

  def get_registered_name_process_id(_node, _name, {:ok, last_result}), do:
    {:ok, {:ok, last_result}}

  def get_registered_name_process_id(node, name, _last_result), do:
    get_pid_rpc(node, Process, :whereis, [name])

  def get_pg2_name_process_id(_node, _name, {:ok, last_result}), do:
    {:ok, {:ok, last_result}}

  def get_pg2_name_process_id(node, name, _last_result), do:
    get_pid_rpc(node, :pg2, :get_local_members, [name])

  defp get_pid_rpc(node, m, f, a) do
    case :rpc.call(node, m, f, a) do
      {:badrpc, result} ->
        {:ok, {:error, result}}

      {:error, result} ->
        {:ok, {:error, result}}

      result when is_pid(result) ->
        {:ok, {:ok, result}}

      [result] when is_pid(result) ->
        {:ok, {:ok, result}}

      result when is_list(result) ->
        {:ok, {:ok, result}}

      _ ->
        {:ok, :exception}
    end
  end

  defp eval_string(processes) do
    {evaled, _} = Code.eval_string("["<> processes <> "]")
    evaled
  end

  ## For Erlang devs
  defp make_possible_atom(item) do
    first = String.to_charlist(String.at(item, 0)) |> hd()
    if first > 96 && first < 123, do: ":" <> item, else: item
  end

  defp do_start_tracing(pids, node, opts) do
    max_events = Keyword.get(opts, :msgs, @maximum_events)
    max_events = String.to_integer(if max_events == "infinity" do "-1" else max_events end)

    {trace_type, trace_mod_funs, p_opts} = get_trace_opts(node, opts)
    my_pid = self()

    :dbg.stop_clear()
    :dbg.start()

    :dbg.tracer(
      node,
      :process,
      {fn
         _, ^max_events ->
           send(my_pid, :done)
           max_events + 1

         m, n ->
           send(my_pid, m)
           n + 1
       end, 0}
    )

    ## Cleanup tracers if we crash
    my_node = node()
    Node.spawn(node, fn -> __MODULE__.external_cleanup(my_node, pids) end)

    case trace_type do
      :code ->
        for [m, f] <- trace_mod_funs, do: :dbg.tpl(m, f, :_, [{:_, [], [{:return_trace}]}])
        for pid <- pids, do: :dbg.p(pid, [:c | p_opts])

      :both ->
        for [m, f] <- trace_mod_funs, do: :dbg.tpl(m, f, :_, [{:_, [], [{:return_trace}]}])
        for pid <- pids, do: :dbg.p(pid, [:c, :m | p_opts])

      :messages ->
        for pid <- pids, do: :dbg.p(pid, [:m | p_opts])
    end

    term_reason = print_messages(Keyword.get(opts, :noargs, false))

    {pids, term_reason}
  end

  defp print_messages(no_arguments) do
    receive do
      :done ->
        :messages_exceeded

      {:signal, signal} ->
        signal

      {:trace_ts, p, :send, _, w, t} when no_arguments ->
        IO.inspect({:trace_ts, p, :msg_send, :no_args, [to: w], t})
        IO.puts("")
        print_messages(no_arguments)

      {:trace, p, :send, _, w} when no_arguments ->
        IO.inspect({:trace, p, :msg_send, :no_args, to: w})
        IO.puts("")
        print_messages(no_arguments)

      {:trace_ts, p, :receive, _, t} when no_arguments ->
        IO.inspect({:trace_ts, p, :msg_receive, :no_args, t})
        IO.puts("")
        print_messages(no_arguments)

      {:trace, p, :receive, _} when no_arguments ->
        IO.inspect({:trace_ts, p, :msg_receive, :no_args})
        IO.puts("")
        print_messages(no_arguments)

      {:trace_ts, {m, f, _}, t} when no_arguments ->
        IO.inspect({:trace_ts, {m, f, :no_args}, t})
        IO.puts("")
        print_messages(no_arguments)

      {:trace, {m, f, _}} when no_arguments ->
        IO.inspect({:trace, {m, f, :no_args}})
        IO.puts("")
        print_messages(no_arguments)

      {:trace_ts, p, w, {m, f, _}, t} when no_arguments ->
        IO.inspect({:trace_ts, p, w, {m, f, :no_args}, t})
        IO.puts("")
        print_messages(no_arguments)

      {:trace, p, w, {m, f, _}} when no_arguments ->
        IO.inspect({:trace, p, w, {m, f, :no_args}})
        IO.puts("")
        print_messages(no_arguments)

      {:trace_ts, p, :return_from, o, _, t} when no_arguments ->
        IO.inspect({:trace_ts, p, :return_from, o, :no_args, t})
        IO.puts("")
        print_messages(no_arguments)

      {:trace, p, :return_from, o, _} when no_arguments ->
        IO.inspect({:trace, p, :return_from, o, :no_args})
        IO.puts("")
        print_messages(no_arguments)

      {:trace_ts, p, w, o, {:ok, _, _}, t} when no_arguments ->
        IO.inspect({:trace_ts, p, w, o, :no_args, t})
        IO.puts("")
        print_messages(no_arguments)

      {:trace, p, w, o, {:ok, _, _}} when no_arguments ->
        IO.inspect({:trace, p, w, o, :no_args})
        IO.puts("")
        print_messages(no_arguments)

      {:trace_ts, p, w, o, {m, f, _}, t} when no_arguments ->
        IO.inspect({:trace_ts, p, w, o, {m, f, :no_args}, t})
        IO.puts("")
        print_messages(no_arguments)

      {:trace, p, w, o, {m, f, _}} when no_arguments ->
        IO.inspect({:trace, p, w, o, {m, f, :no_args}})
        IO.puts("")
        print_messages(no_arguments)

      {:trace_ts, p, w, o, _, t} when no_arguments ->
        IO.inspect({:trace_ts, p, w, o, :no_args, t})
        IO.puts("")
        print_messages(no_arguments)

      {:trace, p, w, o, _} when no_arguments ->
        IO.inspect({:trace, p, w, o, :no_args})
        IO.puts("")
        print_messages(no_arguments)

      {:trace_ts, p, :send, b, d, t} ->
        IO.inspect({:trace_ts, p, :msg_send, b, [to: d], t})
        IO.puts("")
        print_messages(no_arguments)

      {:trace, p, :send, b, d} ->
        IO.inspect({:trace_ts, p, :msg_send, b, to: d})
        IO.puts("")
        print_messages(no_arguments)

      {:trace_ts, p, :receive, b, t} ->
        IO.inspect({:trace_ts, p, :msg_receive, b, t})
        IO.puts("")
        print_messages(no_arguments)

      {:trace, p, :receive, b} ->
        IO.inspect({:trace_ts, p, :msg_receive, b})
        IO.puts("")
        print_messages(no_arguments)

      msg ->
        IO.inspect(msg)
        IO.puts("")
        print_messages(no_arguments)
    end
  end

  defp get_trace_opts(node, opts) do
    trace_type = Keyword.get(opts, :type, "messages")
    mod_fun = Keyword.get(opts, :mf, "_:_")

    p_opts =
      Enum.reduce(@pops, [], fn {k, _} = _d, acc ->
        if Keyword.get(opts, k) do
          [k | acc]
        else
          acc
        end
      end)

    trace_mod_funs = get_trace_mod_funs(node, mod_fun)
    {String.to_atom(trace_type), trace_mod_funs, p_opts}
  end

  defp get_trace_mod_funs(_node,mod_fun) do
      Enum.map(String.split(mod_fun, ","), fn mf -> format_mod_fun(String.split(mf, ":")) end)
  end

  defp format_mod_fun([module, function]) do
    [format_registered_name_or_module(module), String.to_atom(function)]
  end

  defp format_registered_name_or_module("_"), do: :_

  defp format_registered_name_or_module(name) when is_tuple(name), do: name

  defp format_registered_name_or_module(name) when is_list(name), do:
    format_registered_name_or_module(to_string(name))

  defp format_registered_name_or_module(name) do
    if is_elixir_module?(name) do
      if String.contains?(name, "Elixir"),
         do: String.to_atom(name),
         else: String.to_atom("Elixir." <> name)
    else
      String.to_atom(name)
    end
  end

  defp is_elixir_module?(module) do
    first = String.at(module, 0)
    String.upcase(first) == first
  end

  defp help() do

    IO.puts("
    \neztracer:
    \n --node [node]: the Erlang VM you want tracing on
    \n --cookie [cookie]: the VM cookie (optional)
    \n --processes [pid, reg_name or gp2 group]: the remote process pid (e.g. \"<0.249.0>\") or registered name you want to trace (other options ranch or pg2 group)
    \n --msgs [integer]: how many trace events it will receive before terminating (default 100 or the word infinity)
    \n --type [type]: one of \"messages\", \"code\" or \"both\" to trace process messages, code executed or both (default messages)
    \n --sos: if present will apply tracing to any process spawned by those defined in --processes
    \n --sol: if present will apply tracing to any process linked to by those defined in --processes
    \n --timestamp: if present applies a timestamp to the end of each event
    \n --noargs: if present will attempt to suppress the display of any arguments
    \n --mf [string]: a comma separated list of module:fun of which modules and functions to trace, with underscore _ as a wildcard.
              Example \"Foo:bar,MyApp:_\" will trace calls to Foo:bar and all calls to MyApp (default is \"_:_\")
    \n --help: this page\n
  ")

    System.halt()
  end
end

defmodule EZTracerConnect do

  def connect(args) do

    my_name = "eztracer"

    node = if args[:node], do: format_node(args[:node]), else: raise("error connecting")

    Application.start(:inets)

    my_name = if args[:myname], do: args[:myname], else: my_name <> "@localhost"
    :net_kernel.start([String.to_atom(my_name), find_dist_type(node)])

    case args[:cookie] do
      nil -> :ok
      cookie -> :erlang.set_cookie(node(), String.to_atom(cookie))
    end

    if :net_adm.ping(node) == :pang, do: raise("not connected"), else: node
  end

  defp format_node(node) do
   [name, address] = String.split(node, "@")
    case :inet.parse_address(to_charlist(address)) do
      {:ok, _} -> String.to_atom(node)
      _ -> get_address(name, address, node)
    end
  end

  defp get_address(name, address, node) do
    case :inet_res.gethostbyname(String.to_atom(address)) do
      {:ok, {:hostent, _, [], :inet, _, addresses}} ->
        parsed = :inet.ntoa(hd(addresses)) |> to_string()
        String.to_atom("#{name}@#{parsed}")
      _ ->
        String.to_atom(node)
    end
  end

  defp find_dist_type(node) do
    if String.contains?(Atom.to_string(node), ".") do :longnames else :shortnames end
  end

end

defmodule SignalHandler do
  @behaviour :gen_event

  def init({[tracer_pid], _}) do
    {:ok, %{tracer_pid: tracer_pid}}
  end

  def handle_event(signal, %{tracer_pid: pid} = state) do
    send(pid, {:signal, signal})
    {:ok, state}
  end

  def handle_call(_, state), do: {:ok, :ok, state}

  def terminate(_reason, _state), do: :ok
end
