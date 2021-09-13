# eztracer

Provides a tracing tool for monitoring function calls and process to process messages to or from one or many processes.

### Options

#### Processes
The argument `--processes` is a list of processes, or a single process, that should be monitored. A process can be a pid in the form <x.y.z> or a registered process name. If it's a name it will assume it's an atom, it will also accept a tuples in case of PG2 group searches. It will first find any registered processes of that name, and if that fails a PG2 group. Originally it was designed to work with the `ranch` socket acceptor (https://github.com/ninenines/ranch). With that in mind your can specify the word `ranch' and it will attempt to trace calls to that application. You should also specify the arguments `--sol` and `--sos` in this case. NOTE: The`ranch` option has not been tested on all versions.

**Example:**
`--processes "ranch,<0.1137.0>,AwesomeApp.Emailer,:erl_epmd,{phx,AwsomeApp.PubSub}"`

#### Module/Function
The argument `--mf` specifies a list of modules and functions you wish to monitor. It takes the format `"M:F"`, and underscore is a wildcard so `"_:_"` will cause the processes been monitored to trace calls to/from every module and function that is loaded in the runtime (so should be avoided). 

**Example:**
`--mf "ets:_,AwesomeApp.Emailer:send_mail,Enum:_` will indicate calls to the `ets` module to the module:function `AwesomeApp.Emailer:send_mail` and all calls to the `Enum` module.

#### Timestamp
The argument `--timestamp` will add the current date/time to every event, it uses Erlang's `:os.timestamp()`, so if you can match a function `:call` with the `:return_from` you can calculate the time spent with `:timer.now_diff/2`.

#### Other options
`--sos` will cause the tracer options to be passed to any child processes of the ones been monitored
`--sol` will cause the tracer options to be passed to any processes linked be the ones been monitored
`--noargs` will attempt to filter out the arguments contained in a function call or message
`--type` what to monitor, `messages` will monitor messages only, `code` will monitor function calls only or `both` will do both code and messages
`--msgs` how many events to trace before terminating. The default is 100 the word `infinity` will never stop

## Compiling

Execute `mix escript.build`

## Usage
```
eztracer --help

eztracer:

 --node [node]: the Erlang VM you want tracing on

 --cookie [cookie]: the VM cookie (optional)

 --processes [pid, reg_name or gp2 group]: the remote process pid (e.g. "<0.249.0>") or registered name you want to trace (other options ranch or pg2 group)

 --msgs [integer]: how many trace events it will receive before terminating (default 100 or the word infinity)

 --type [type]: one of "messages", "code" or "both" to trace process messages, code executed or both (default messages)

 --sos: if present will apply tracing to any process spawned by those defined in --processes

 --sol: if present will apply tracing to any process linked to by those defined in --processes

 --timestamp: if present applies a timestamp to the end of each event

 --noargs: if present will attempt to suppress the display of any arguments

 --mf [string]: a comma separated list of module:fun of which modules and functions to trace, with underscore _ as a wildcard.
              Example "Foo:bar,MyApp:_" will trace calls to Foo:bar and all calls to MyApp (default is "_:_")

 --help: this page

```

## Example Output 
```

{:trace_ts, #PID<9239.3729.0>, :call,
 {CollectionServer.Types.Range, :cast,
  [
    {0, 0},
    %{
      parent: %{
        __dirty__: false,
        __struct__: CollectionServer.Types.UserInfo,
        account_version: 0,
        admin: false,
        claimed: true,
        collection_id: %{
          __struct__: CollectionServer.Types.UUID,
          value: <<249, 145, 98, 152, 253, 154, 74, 99, 171, 235, 144, 133, 201,
            155, 18, 120>>
        },
        default_collection_id: nil,
        deleted: false,
        devices: nil,
        display_name: "bob smith",
        entity_id: nil,
        entity_metadata: nil,
        key_range: nil,
        public_key: nil,
        storage_backend: nil,
        user_id: nil
      }
    }
  ]}, {1621, 20060, 336917}}

{:trace_ts, #PID<9239.3729.0>, :return_from,
 {CollectionServer.Types.Range, :cast, 2},
 {:ok, %{__struct__: CollectionServer.Types.Range, lower: 0, upper: 0}},
 {1621, 20060, 336919}}

```
```
iex(1)> :timer.now_diff({1621, 20060, 336919}, {1621, 20060, 336917}) 
2
```
So this function call took `2` microseconds. Dependng on how `--mf` is specified there can be a lot of nesting of function calls.
