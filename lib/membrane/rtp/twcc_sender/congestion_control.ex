defmodule Membrane.RTP.TWCCSender.CongestionControl do
  @moduledoc """
  The module implements [Google congestion control algorithm](https://datatracker.ietf.org/doc/html/draft-ietf-rmcat-gcc-02).
  """

  require Membrane.Logger

  alias Membrane.Time

  # disable Credo naming checks to use the RFC notation
  # credo:disable-for-this-file /(ModuleAttributeNames|VariableNames)/

  # state noise covariance
  @q 0.001
  # filter coefficient for the measured noise variance, between [0.1, 0.001]
  @chi 0.01

  # decrease rate factor
  @beta 0.85

  # coefficients for the adaptive threshold (reffered to as "K_u", "K_d" in the RFC)
  @coeff_K_u 0.01
  @coeff_K_d 0.00018

  # alpha factor for exponential moving average
  @ema_smoothing_factor 0.95

  @last_receive_rates_size 25
  @decrease_r_hats_size 25

  defstruct [
    # inter-packet delay estimate (in ms)
    m_hat: 0.0,
    # system error covariance
    e: 0.1,
    # estimate for the state noise variance
    var_v_hat: 0.0,
    # initial value for the adaptive threshold, 12.5ms
    del_var_th: 12.5,
    # last rates at which packets were received
    last_receive_rates: [],
    # current delay-based controller state
    state: :increase,
    # timestamp indicating when we started to overuse the link
    overuse_start_ts: nil,
    # timestamp indicating when we started to underuse the link
    underuse_start_ts: nil,
    # latest timestamp indicating when the receiver-side bandwidth was increased
    last_bandwidth_increase_ts: Time.vm_time(),
    # receiver-side bandwidth estimation in bps
    a_hat: 300_000.0,
    # sender-side bandwidth estimation in bps
    as_hat: 300_000.0,
    # latest receiver-side incoming bitrates when we were in the decrease state
    decrease_r_hats: [],
    # latest receiver-side incoming bitrate
    last_r_hat: nil,
    # time window for measuring the received bitrate, between [0.5, 1]s (reffered to as "T" in the RFC)
    target_receive_window: Time.milliseconds(750),
    # accumulator for packets and their timestamps that have been received through target_receive_interval
    packets_received: [],
    # time required to trigger a signal (reffered to as "overuse_time_th" in the RFC)
    signal_time_threshold: Time.milliseconds(10)
  ]

  @type t :: %__MODULE__{
          m_hat: float(),
          e: float(),
          var_v_hat: float(),
          del_var_th: float(),
          last_receive_rates: [float()],
          state: :increase | :decrease | :hold,
          overuse_start_ts: Time.t() | nil,
          underuse_start_ts: Time.t() | nil,
          last_bandwidth_increase_ts: Time.t(),
          a_hat: float(),
          as_hat: float(),
          decrease_r_hats: [float()],
          last_r_hat: float() | nil,
          packets_received: [{Membrane.Time.t(), non_neg_integer()}]
        }

  @spec update(t(), Time.t(), [Time.t() | :not_received], [Time.t()], [pos_integer()], Time.t()) ::
          t()
  def update(
        %__MODULE__{} = cc,
        reference_time,
        receive_deltas,
        send_deltas,
        packet_sizes,
        rtt
      ) do
    cc
    |> update_metrics(receive_deltas, send_deltas)
    |> update_receiver_bitrate(reference_time, receive_deltas, packet_sizes)
    |> update_receiver_bandwidth(packet_sizes, rtt)
    |> update_sender_bandwidth(receive_deltas)
  end

  defp update_metrics(cc, [], []), do: cc

  defp update_metrics(cc, [:not_received | recv_deltas], [send_delta | send_deltas]) do
    case {recv_deltas, send_deltas} do
      {[], []} ->
        cc

      {recv_deltas, [next_send_delta | other_send_deltas]} ->
        update_metrics(cc, recv_deltas, [send_delta + next_send_delta | other_send_deltas])
    end
  end

  defp update_metrics(cc, [recv_delta | recv_deltas], [send_delta | send_deltas])
       when recv_delta < 0 do
    case {recv_deltas, send_deltas} do
      {[], []} ->
        cc

      {[:not_received | other_recv_deltas], [next_send_delta | other_send_deltas]} ->
        update_metrics(cc, [recv_delta | other_recv_deltas], [
          send_delta + next_send_delta | other_send_deltas
        ])

      {[next_recv_delta | other_recv_deltas], [next_send_delta | other_send_deltas]} ->
        update_metrics(cc, [recv_delta + next_recv_delta | other_recv_deltas], [
          send_delta + next_send_delta | other_send_deltas
        ])
    end
  end

  defp update_metrics(cc, [recv_delta | recv_deltas], [send_delta | send_deltas]) do
    %__MODULE__{
      m_hat: prev_m_hat,
      e: e,
      var_v_hat: var_v_hat,
      del_var_th: del_var_th,
      last_receive_rates: last_receive_rates
    } = cc

    [recv_delta_ms, send_delta_ms] = Enum.map([recv_delta, send_delta], &Time.to_milliseconds/1)

    interpacket_delta = recv_delta_ms - send_delta_ms

    z = interpacket_delta - prev_m_hat

    last_receive_rates = [1 / max(recv_delta_ms, 1) | last_receive_rates]

    f_max = Enum.max(last_receive_rates)

    alpha = :math.pow(1 - @chi, 30 / (1000 * f_max))

    var_v_hat = max(alpha * var_v_hat + (1 - alpha) * z * z, 1)

    k = (e + @q) / (var_v_hat + e + @q)

    e = (1 - k) * (e + @q)

    coeff = min(z, 3 * :math.sqrt(var_v_hat))

    m_hat = prev_m_hat + coeff * k
    abs_m_hat = abs(m_hat)

    del_var_th =
      if abs_m_hat - del_var_th <= 15 do
        coeff_K = if abs_m_hat < del_var_th, do: @coeff_K_d, else: @coeff_K_u
        gain = recv_delta_ms * coeff_K * (abs_m_hat - del_var_th)
        max(min(del_var_th + gain, 600), 6)
      else
        del_var_th
      end

    cc = %__MODULE__{
      cc
      | m_hat: m_hat,
        var_v_hat: var_v_hat,
        e: e,
        last_receive_rates: Enum.take(last_receive_rates, @last_receive_rates_size),
        del_var_th: del_var_th
    }

    cc
    |> make_signal(prev_m_hat)
    |> then(fn {signal, cc} -> update_state(cc, signal) end)
    |> update_metrics(recv_deltas, send_deltas)
  end

  defp make_signal(%__MODULE__{m_hat: m_hat, del_var_th: del_var_th} = cc, prev_m_hat)
       when m_hat < -del_var_th do
    now = Time.vm_time()

    underuse_start_ts = cc.underuse_start_ts || now

    trigger_underuse? =
      now - underuse_start_ts >= cc.signal_time_threshold and m_hat <= prev_m_hat

    if trigger_underuse? do
      {:underuse, %__MODULE__{cc | underuse_start_ts: now, overuse_start_ts: nil}}
    else
      {:no_signal, %__MODULE__{cc | underuse_start_ts: underuse_start_ts, overuse_start_ts: nil}}
    end
  end

  defp make_signal(%__MODULE__{m_hat: m_hat, del_var_th: del_var_th} = cc, prev_m_hat)
       when m_hat > del_var_th do
    now = Time.vm_time()

    overuse_start_ts = cc.overuse_start_ts || now

    trigger_overuse? = now - overuse_start_ts >= cc.signal_time_threshold and m_hat >= prev_m_hat

    if trigger_overuse? do
      {:overuse, %__MODULE__{cc | underuse_start_ts: nil, overuse_start_ts: now}}
    else
      {:no_signal, %__MODULE__{cc | underuse_start_ts: nil, overuse_start_ts: overuse_start_ts}}
    end
  end

  defp make_signal(cc, _prev_m_hat),
    do: {:normal, %__MODULE__{cc | underuse_start_ts: nil, overuse_start_ts: nil}}

  # +----+--------+-----------+------------+--------+
  # |     \ State |   Hold    |  Increase  |Decrease|
  # |      \      |           |            |        |
  # | Signal\     |           |            |        |
  # +--------+----+-----------+------------+--------+
  # |  Over-use   | Decrease  |  Decrease  |        |
  # +-------------+-----------+------------+--------+
  # |  Normal     | Increase  |            |  Hold  |
  # +-------------+-----------+------------+--------+
  # |  Under-use  |           |   Hold     |  Hold  |
  # +-------------+-----------+------------+--------+

  defp update_state(cc, signal)

  defp update_state(%__MODULE__{state: :hold} = cc, :overuse),
    do: %__MODULE__{cc | state: :decrease}

  defp update_state(%__MODULE__{state: :hold} = cc, :normal),
    do: %__MODULE__{cc | state: :increase}

  defp update_state(%__MODULE__{state: :increase} = cc, :overuse),
    do: %__MODULE__{cc | state: :decrease}

  defp update_state(%__MODULE__{state: :increase} = cc, :underuse),
    do: %__MODULE__{cc | state: :hold}

  defp update_state(%__MODULE__{state: :decrease} = cc, :normal),
    do: %__MODULE__{cc | state: :hold}

  defp update_state(%__MODULE__{state: :decrease} = cc, :underuse),
    do: %__MODULE__{cc | state: :hold}

  defp update_state(cc, _signal), do: cc

  defp update_receiver_bitrate(
         %__MODULE__{last_r_hat: nil} = cc,
         reference_time,
         receive_deltas,
         packet_sizes
       ) do
    %__MODULE__{target_receive_window: receive_window} = cc

    packets_received = resolve_receive_deltas(receive_deltas, reference_time, packet_sizes)

    packets_received = cc.packets_received ++ packets_received

    {first_packet_timestamp, _first_packet_size} = List.first(packets_received)
    {last_packet_timestamp, _last_packet_size} = List.last(packets_received)

    if last_packet_timestamp - first_packet_timestamp >= receive_window do
      cc = %__MODULE__{cc | last_r_hat: 0.0, packets_received: packets_received}
      update_receiver_bitrate(cc, reference_time, receive_deltas, packet_sizes)
    else
      %__MODULE__{cc | packets_received: packets_received}
    end
  end

  defp update_receiver_bitrate(cc, reference_time, receive_deltas, packet_sizes) do
    %__MODULE__{target_receive_window: receive_window} = cc

    packets_received = resolve_receive_deltas(receive_deltas, reference_time, packet_sizes)

    {last_packet_timestamp, _last_packet_size} = List.last(packets_received)

    treshold = last_packet_timestamp - receive_window

    packets_received =
      (cc.packets_received ++ packets_received)
      |> Enum.drop_while(fn {timestamp, _size} -> timestamp < treshold end)

    packet_received_sizes = Enum.map(packets_received, fn {_timestamp, size} -> size end)

    r_hat =
      1 / (Time.as_milliseconds(cc.target_receive_window) / 1000) *
        Enum.sum(packet_received_sizes)

    %__MODULE__{cc | last_r_hat: r_hat, packets_received: packets_received}
  end

  defp resolve_receive_deltas(receive_deltas, reference_time, packet_sizes) do
    receive_deltas
    |> Enum.zip(packet_sizes)
    |> Enum.filter(fn {delta, _size} -> delta != :not_received end)
    |> Enum.scan({reference_time, List.first(packet_sizes)}, fn {recv_delta, size},
                                                                {prev_timestamp, _prev_size} ->
      {prev_timestamp + recv_delta, size}
    end)
  end

  # wait until we calculate first r_hat as it is needed
  # both for increasing and decreasing bwe
  defp update_receiver_bandwidth(%__MODULE__{last_r_hat: nil} = cc, _packet_sizes, _rtt), do: cc

  defp update_receiver_bandwidth(%__MODULE__{state: state} = cc, packet_sizes, rtt) do
    case state do
      :increase -> increase_receiver_bandwidth(cc, packet_sizes, rtt)
      :decrease -> decrease_receiver_bandwidth(cc)
      :hold -> cc
    end
  end

  defp increase_receiver_bandwidth(cc, packet_sizes, rtt) do
    %__MODULE__{
      a_hat: prev_a_hat,
      last_bandwidth_increase_ts: last_bandwidth_increase_ts
    } = cc

    now = Time.vm_time()
    last_bandwidth_increase_ts = last_bandwidth_increase_ts || now
    time_since_last_update_ms = Time.to_milliseconds(now - last_bandwidth_increase_ts)

    a_hat =
      case bitrate_increase_mode(cc) do
        :multiplicative ->
          eta = :math.pow(1.08, min(time_since_last_update_ms / 1000, 1))
          eta * prev_a_hat

        :additive ->
          response_time_ms = 100 + Time.to_milliseconds(rtt)
          alpha = 0.5 * min(time_since_last_update_ms / response_time_ms, 1)
          expected_packet_size_bits = Enum.sum(packet_sizes) / length(packet_sizes)
          prev_a_hat + max(1000, alpha * expected_packet_size_bits)
      end

    a_hat = min(1.5 * cc.last_r_hat, a_hat)

    %__MODULE__{cc | a_hat: a_hat, last_bandwidth_increase_ts: now}
  end

  defp decrease_receiver_bandwidth(cc) do
    %__MODULE__{
      cc
      | a_hat: @beta * cc.last_r_hat,
        decrease_r_hats: Enum.take([cc.last_r_hat | cc.decrease_r_hats], @decrease_r_hats_size)
    }
  end

  defp update_sender_bandwidth(%__MODULE__{as_hat: as_hat, a_hat: a_hat} = cc, receive_deltas) do
    lost = Enum.count(receive_deltas, &(&1 == :not_received))
    loss_ratio = lost / length(receive_deltas)

    as_hat =
      cond do
        loss_ratio < 0.02 -> 1.05 * as_hat
        loss_ratio > 0.1 -> as_hat * (1 - 0.5 * loss_ratio)
        true -> as_hat
      end

    %__MODULE__{cc | as_hat: min(as_hat, 1.5 * a_hat)}
  end

  defp bitrate_increase_mode(%__MODULE__{decrease_r_hats: []}), do: :multiplicative

  defp bitrate_increase_mode(%__MODULE__{decrease_r_hats: decrease_r_hats, last_r_hat: last_r_hat}) do
    exp_average = exponential_moving_average(@ema_smoothing_factor, decrease_r_hats)
    std_dev = std_dev(decrease_r_hats)

    if abs(last_r_hat - exp_average) <= 3 * std_dev do
      :additive
    else
      :multiplicative
    end
  end

  defp exponential_moving_average(_alpha, []), do: 0

  defp exponential_moving_average(alpha, [latest_observation | older_observations]) do
    alpha * latest_observation +
      (1 - alpha) * exponential_moving_average(alpha, older_observations)
  end

  defp std_dev(observations) when observations != [] do
    n_obs = length(observations)
    mean = Enum.sum(observations) / n_obs

    observations
    |> Enum.reduce(0, fn obs, acc -> acc + (obs - mean) * (obs - mean) end)
    |> then(&(&1 / n_obs))
    |> :math.sqrt()
  end
end
