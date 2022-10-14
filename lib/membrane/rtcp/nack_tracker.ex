defmodule Membrane.RTCP.NACKTracker do
  @moduledoc """
  A struct keeping state of NACKs. It allows to register received and missing sequence numbers,
  then check if NACK for any has to be sent at a given time.
  """
  alias Membrane.Time
  alias Membrane.RTP

  @await_reordered_time Time.milliseconds(10)
  @max_attempts 5

  @backoff_factor 1.25
  @min_interval Time.milliseconds(20)
  @max_interval Time.milliseconds(400)

  defmodule Entry do
    @moduledoc false
    @enforce_keys [:last_sent_at]
    defstruct @enforce_keys ++ [attempts: 0]
  end

  @type t() :: %__MODULE__{
          rtt: Membrane.Time.t(),
          nack_states: %{RTP.Header.sequence_number_t() => %Entry{}}
        }

  defstruct rtt: @min_interval, nack_states: %{}

  @doc """
  Initializes a new NACKTracker
  """
  @spec new() :: t()
  def new(), do: %__MODULE__{}

  def set_rtt(tracker, rtt) do
    %__MODULE__{tracker | rtt: rtt}
  end

  def received(tracker, sequence_number) do
    %__MODULE__{tracker | nack_states: Map.delete(tracker.nack_states, sequence_number)}
  end

  def gap(tracker, sequence_numbers, received_at \\ nil) do
    received_at = received_at || Membrane.Time.vm_time()
    nack_entries = sequence_numbers |> Map.new(&{&1, %Entry{last_sent_at: received_at}})
    %__MODULE__{tracker | nack_states: Map.merge(tracker.nack_states, nack_entries)}
  end

  def to_send(tracker, at \\ nil) do
    at = at || Membrane.Time.vm_time()

    tracker.nack_states
    |> Bunch.KVEnum.filter_by_values(fn
      %Entry{attempts: attempts, last_sent_at: last_sent_at} ->
        should_be_sent_at = last_sent_at + calculate_backoff(attempts, tracker.rtt)

        should_be_sent_at <= at
    end)
    |> Bunch.KVEnum.keys()
  end

  def updated_nacked(tracker, seq_nums, sent_at) do
    updated_nack_states =
      tracker.nack_states
      |> Map.take(seq_nums)
      |> Enum.map(fn {sn, entry} ->
        {sn,
         %Entry{
           entry
           | attempts: entry.attempts + 1,
             last_sent_at: sent_at
         }}
      end)
      |> Enum.reject(fn {_sn, entry} -> entry.attempts >= @max_attempts end)
      |> Map.new()

    %__MODULE__{tracker | nack_states: Map.merge(tracker.nack_states, updated_nack_states)}
  end

  # Based on https://github.com/livekit/livekit/blob/1d2bca373b08010be2aa5971f588701a83a391f4/pkg/sfu/buffer/nack.go
  defp calculate_backoff(0, _rtt) do
    @await_reordered_time
  end

  defp calculate_backoff(attempts, rtt) do
    backoff = rtt * @backoff_factor ** (attempts - 1)

    cond do
      backoff < @min_interval -> @min_interval
      backoff > @max_interval -> @max_interval
      true -> backoff
    end
  end
end
