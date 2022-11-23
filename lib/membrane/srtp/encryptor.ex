if Code.ensure_loaded?(ExLibSRTP) do
  defmodule Membrane.SRTP.Encryptor do
    @moduledoc """
    Converts plain RTP packets to SRTP.

    Requires adding [srtp](https://github.com/membraneframework/elixir_libsrtp) dependency to work.
    """
    use Membrane.Filter

    require Membrane.Logger

    alias Membrane.{Buffer, RTP, SRTP}

    def_input_pad :input, caps: :any, demand_mode: :auto
    def_output_pad :output, caps: :any, demand_mode: :auto

    def_options policies: [
                  spec: [ExLibSRTP.Policy.t()],
                  default: [],
                  description: """
                  List of SRTP policies to use for encrypting packets.
                  See `t:ExLibSRTP.Policy.t/0` for details.
                  """
                ]

    @impl true
    def handle_init(%__MODULE__{policies: policies}) do
      state = %{
        policies: policies,
        srtp: nil,
        queue: []
      }

      {:ok, state}
    end

    @impl true
    def handle_stopped_to_prepared(_ctx, state) do
      srtp = ExLibSRTP.new()

      state.policies
      |> Bunch.listify()
      |> Enum.each(&ExLibSRTP.add_stream(srtp, &1))

      {:ok, %{state | srtp: srtp}}
    end

    @impl true
    def handle_start_of_stream(:input, _ctx, state) do
      if state.policies == [] do
        # TODO: remove when dynamic switching between automatic and manual demands will be supported
        {{:ok, start_timer: {:policy_timer, Membrane.Time.seconds(5)}}, state}
      else
        {:ok, state}
      end
    end

    @impl true
    def handle_tick(:policy_timer, ctx, state) do
      if state.policies != [] or ctx.pads.input.end_of_stream? do
        {{:ok, stop_timer: :policy_timer}, state}
      else
        raise "No SRTP policies arrived in 5 seconds"
      end
    end

    @impl true
    def handle_prepared_to_stopped(_ctx, state) do
      {:ok, %{state | srtp: nil, policies: []}}
    end

    @impl true
    def handle_event(_pad, %SRTP.KeyingMaterialEvent{} = event, _ctx, %{policies: []} = state) do
      {:ok, crypto_profile} =
        ExLibSRTP.Policy.crypto_profile_from_dtls_srtp_protection_profile(
          event.protection_profile
        )

      policy = %ExLibSRTP.Policy{
        ssrc: :any_outbound,
        key: event.local_keying_material,
        rtp: crypto_profile,
        rtcp: crypto_profile
      }

      :ok = ExLibSRTP.add_stream(state.srtp, policy)
      buffers = state.queue |> Enum.reverse() |> Enum.flat_map(&protect_buffer(&1, state.srtp))
      {{:ok, buffer: {:output, buffers}}, %{Map.put(state, :policies, [policy]) | queue: []}}
    end

    @impl true
    def handle_event(_pad, %SRTP.KeyingMaterialEvent{}, _ctx, state) do
      Membrane.Logger.warn("Got unexpected SRTP.KeyingMaterialEvent. Ignoring.")
      {:ok, state}
    end

    @impl true
    def handle_event(pad, other, ctx, state), do: super(pad, other, ctx, state)

    @impl true
    def handle_process(:input, buffer, _ctx, %{policies: []} = state) do
      {:ok, Map.update!(state, :queue, &[buffer | &1])}
    end

    @impl true
    def handle_process(:input, buffer, _ctx, state) do
      {{:ok, buffer: {:output, protect_buffer(buffer, state.srtp)}}, state}
    end

    defp protect_buffer(buffer, srtp) do
      %Buffer{payload: payload} = buffer
      packet_type = RTP.Packet.identify(payload)

      {protect_function, expected_errors} =
        case packet_type do
          :rtp -> {&ExLibSRTP.protect/2, [:replay_fail, :replay_old]}
          :rtcp -> {&ExLibSRTP.protect_rtcp/2, []}
        end

      case protect_function.(srtp, payload) do
        {:ok, payload} ->
          [%Buffer{buffer | payload: payload}]

        {:error, reason} ->
          if reason in expected_errors do
            Membrane.Logger.warn("Ignoring #{inspect(packet_type)} packet due to `#{reason}`")
            []
          else
            raise "Failed to protect #{inspect(packet_type)} due to unhandled error #{reason}"
          end
      end
    end
  end
end
