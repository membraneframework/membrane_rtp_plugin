defmodule Membrane.RTP.Header do
  @moduledoc """
  Describes RTP Header defined in [RFC3550](https://tools.ietf.org/html/rfc3550#page-13)

  ```
   0                   1                   2                   3
   0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |V=2|P|X|  CC   |M|     PT      |       sequence number         |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                           timestamp                           |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |           synchronization source (SSRC) identifier            |
  +=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+
  |            contributing source (CSRC) identifiers             |
  |                             ....                              |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  ```
  """

  alias Membrane.RTP

  @typedoc """
  This field identifies the version of RTP. The version defined by this specification is 2.
  """
  @type version :: 0..2

  @typedoc """
  Indicates whether a packet contains additional padding at the end.
  The last octet of the padding contains a count of padding octets that should be ignored, including itself.
  """
  @type padding :: boolean()

  @typedoc """
  If the extension bit is set, the fixed header MUST be followed by exactly one header extension
  """
  @type extension :: boolean()

  @typedoc """
  The interpretation of the marker is defined by a profile
  """
  @type marker :: boolean()

  @typedoc """
  Timestamp of a packet in ticks of clock according to `t:RTP.clock_rate_t/0`.

  Its initial value is random, so it should not be interpreted as an absolute time, but rather used to calculate
  time difference from other timestamps.
  """
  @type timestamp_t() :: non_neg_integer()

  @typedoc """
  A 16-bit integer sequential number of a packet.

  Its initial value should be random.
  """
  @type sequence_number_t() :: non_neg_integer()

  @type t :: %__MODULE__{
          version: version(),
          padding: padding(),
          extension_header: extension(),
          csrc_count: 0..15,
          ssrc: RTP.ssrc_t(),
          marker: marker(),
          payload_type: RTP.payload_type_t(),
          timestamp: timestamp_t(),
          sequence_number: sequence_number_t(),
          csrcs: [non_neg_integer()],
          extension_header_data: __MODULE__.Extension.t() | nil
        }

  @enforce_keys [
    :version,
    :padding,
    :extension_header,
    :csrc_count,
    :ssrc,
    :marker,
    :payload_type,
    :timestamp,
    :sequence_number,
    :csrcs
  ]
  defstruct @enforce_keys ++ [:extension_header_data]
end
