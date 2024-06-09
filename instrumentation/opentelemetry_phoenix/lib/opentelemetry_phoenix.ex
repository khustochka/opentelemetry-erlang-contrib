defmodule OpentelemetryPhoenix do
  @options_schema NimbleOptions.new!(
                    endpoint_prefix: [
                      type: {:list, :atom},
                      default: [:phoenix, :endpoint],
                      doc: "The endpoint prefix in your endpoint."
                    ],
                    adapter: [
                      type: {:in, [:cowboy2, :bandit]},
                      default: :cowboy2,
                      required: true,
                      doc: "The phoenix server adapter being used.",
                      type_doc: ":atom"
                    ],
                    liveview: [
                      type: :boolean,
                      default: true,
                      doc: "Whether LiveView traces will be instrumented."
                    ],
                    liveview_include_params: [
                      type: {:or, [:boolean, {:fun, 1}]},
                      default: false,
                      doc: "Whether to include LiveView params into traces. Accepts filter function."
                    ]
                  )

  @moduledoc """
  OpentelemetryPhoenix uses [telemetry](https://hexdocs.pm/telemetry/) handlers to create `OpenTelemetry` spans.

  Current events which are supported include endpoint start/stop, router start/stop,
  and router exceptions.

  ### Supported options
  #{NimbleOptions.docs(@options_schema)}

  #### Adapters

  * `cowboy2` - when using PlugCowboy as your adapter you must add `:opentelemetry_cowboy` to your project
  and pass `adapter: :cowboy2` option when calling setup.
  * `bandit` - when using `Bandit.PhoenixAdapter` as your adapter you must add `:opentelemetry_bandit` to your project
  and pass `adapter: :bandit` option when calling setup

  ## Usage

  In your application start:

      def start(_type, _args) do
        :opentelemetry_cowboy.setup()
        OpentelemetryPhoenix.setup(adapter: :cowboy2)

        children = [
          {Phoenix.PubSub, name: MyApp.PubSub},
          MyAppWeb.Endpoint
        ]

        opts = [strategy: :one_for_one, name: MyStore.Supervisor]
        Supervisor.start_link(children, opts)
      end

  """
  alias OpenTelemetry.SemConv.Incubating.HTTPAttributes

  alias OpenTelemetry.Tracer

  require OpenTelemetry.Tracer

  @tracer_id __MODULE__

  @typedoc "Setup options"
  @type opts :: [endpoint_prefix() | adapter() | liveview()]

  @typedoc "The endpoint prefix in your endpoint. Defaults to `[:phoenix, :endpoint]`"
  @type endpoint_prefix :: {:endpoint_prefix, [atom()]}

  @typedoc "The phoenix server adapter being used. Required"
  @type adapter :: {:adapter, :cowboy2 | :bandit}

  @typedoc "Attach LiveView handlers. Optional"
  @type liveview :: {:liveview, boolean()}

  @doc """
  Initializes and configures the telemetry handlers.
  """
  @spec setup(opts()) :: :ok
  def setup(opts \\ []) do
    opts = NimbleOptions.validate!(opts, @options_schema)

    attach_endpoint_start_handler(opts)
    attach_router_start_handler(opts)

    if opts[:liveview] do
      attach_liveview_handlers(opts)
    end

    :ok
  end

  @doc false
  def attach_endpoint_start_handler(opts) do
    :telemetry.attach(
      {__MODULE__, :endpoint_start},
      opts[:endpoint_prefix] ++ [:start],
      &__MODULE__.handle_endpoint_start/4,
      %{adapter: opts[:adapter]}
    )
  end

  @doc false
  def attach_router_start_handler(_opts) do
    :telemetry.attach(
      {__MODULE__, :router_dispatch_start},
      [:phoenix, :router_dispatch, :start],
      &__MODULE__.handle_router_dispatch_start/4,
      %{}
    )
  end

  def attach_liveview_handlers(opts) do
    :telemetry.attach_many(
      {__MODULE__, :live_view},
      [
        [:phoenix, :live_view, :mount, :start],
        [:phoenix, :live_view, :mount, :stop],
        [:phoenix, :live_view, :mount, :exception],
        [:phoenix, :live_view, :handle_params, :start],
        [:phoenix, :live_view, :handle_params, :stop],
        [:phoenix, :live_view, :handle_params, :exception],
        [:phoenix, :live_view, :handle_event, :start],
        [:phoenix, :live_view, :handle_event, :stop],
        [:phoenix, :live_view, :handle_event, :exception],
        [:phoenix, :live_component, :handle_event, :start],
        [:phoenix, :live_component, :handle_event, :stop],
        [:phoenix, :live_component, :handle_event, :exception]
      ],
      &__MODULE__.handle_liveview_event/4,
      %{include_params: opts[:liveview_include_params]}
    )

    :ok
  end

  # TODO: do we still need exception handling? Only when cowboy?

  @doc false
  def handle_endpoint_start(_event, _measurements, _meta, %{adapter: :bandit}), do: :ok

  def handle_endpoint_start(_event, _measurements, _meta, %{adapter: :cowboy2}) do
    cowboy2_start()
  end

  defp cowboy2_start do
    OpentelemetryProcessPropagator.fetch_parent_ctx()
    |> OpenTelemetry.Ctx.attach()
  end

  @doc false
  def handle_router_dispatch_start(_event, _measurements, meta, _config) do
    attributes = %{
      :"phoenix.plug" => meta.plug,
      :"phoenix.action" => meta.plug_opts,
      HTTPAttributes.http_route() => meta.route
    }

    Tracer.update_name("#{meta.conn.method} #{meta.route}")
    Tracer.set_attributes(attributes)
  end

  def handle_liveview_event(
        [:phoenix, _live, :mount, :start],
        _measurements,
        meta,
        config
      ) do
    %{socket: socket, params: params, uri: url} = meta
    %{view: live_view} = socket

    attributes = %{url: url}
    attributes =
      attributes
      |> maybe_add_params(config, params)

    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      "#{inspect(live_view)}.mount",
      meta,
      %{kind: :server}
    )
    |> OpenTelemetry.Span.set_attributes(attributes)
  end

  def handle_liveview_event(
        [:phoenix, _live, :handle_params, :start],
        _measurements,
        meta,
        config
      ) do
    %{socket: socket, params: params, uri: url} = meta
    %{view: live_view} = socket

    attributes = %{url: url}
    attributes =
      attributes
      |> maybe_add_params(config, params)

    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      "#{inspect(live_view)}.handle_params",
      meta,
      %{kind: :server}
    )
    |> OpenTelemetry.Span.set_attributes(attributes)
  end

  def handle_liveview_event(
        [:phoenix, _live, :handle_event, :start],
        _measurements,
        meta,
        config
      ) do
    %{socket: socket, event: event, params: params} = meta
    %{view: live_view} = socket

    attributes = %{}
    attributes =
      attributes
      |> maybe_add_params(config, params)

    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      "#{inspect(live_view)}.handle_event##{event}",
      meta,
      %{kind: :server}
    )
    |> OpenTelemetry.Span.set_attributes(attributes)
  end

  def handle_liveview_event(
        [:phoenix, _live, _event, :stop],
        _measurements,
        meta,
        _handler_configuration
      ) do
    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end

  def handle_liveview_event(
        [:phoenix, _live, _action, :exception],
        _,
        %{kind: kind, reason: reason, stacktrace: stacktrace} = meta,
        _
      ) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    exception = Exception.normalize(kind, reason, stacktrace)

    OpenTelemetry.Span.record_exception(ctx, exception, stacktrace, [])
    OpenTelemetry.Span.set_status(ctx, OpenTelemetry.status(:error, ""))
    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end

  defp maybe_add_params(attrs, %{include_params: false}, _params) do
    attrs
  end

  defp maybe_add_params(attrs, %{include_params: true}, params) do
    add_params(attrs, params)
  end

  defp maybe_add_params(attrs, %{include_params: params_filter}, params) when is_function(params_filter, 1) do
    add_params(attrs, params_filter.(params))
  end

  defp add_params(attrs, params) do
    attrs
    |> Map.merge(params_to_attrs("params", params))
  end

  defp params_to_attrs(prefix, map) do
    map
    |> (Enum.reduce %{}, fn {key, v}, acc ->
      new_prefix =
        [prefix, key]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(".")
        |> String.to_atom
      case v do
        val when is_map(val) -> Map.merge(acc, params_to_attrs(new_prefix, val))
        val -> Map.put(acc, new_prefix, val)
      end
    end)
  end
end
