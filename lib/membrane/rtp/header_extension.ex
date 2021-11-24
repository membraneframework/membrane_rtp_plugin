defmodule Membrane.RTP.Header.Extension do
  @moduledoc """
  Describes RTP Header Extension defined in [RFC3550](https://tools.ietf.org/html/rfc3550#section-5.3.1)

  ```
   0                   1                   2                   3
   0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |      defined by profile       |           length              |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                        header extension                       |
  |                             ....                              |

  ```
  """
  @enforce_keys [:identifier, :data]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          identifier: 1..14,
          data: binary()
        }
end
