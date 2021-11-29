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
  alias Membrane.Buffer
  alias Membrane.RTP.SessionBin

  @enforce_keys [:identifier, :data]
  defstruct @enforce_keys

  @type identifier_t :: 1..14 | SessionBin.rtp_extension_name_t()

  @type t :: %__MODULE__{
          identifier: identifier_t(),
          data: binary()
        }

  @spec pop_identifier(Buffer.t(), identifier_t()) :: {t() | nil, Buffer.t()}
  def pop_identifier(buffer, identifier) do
    extension = Enum.find(buffer.metadata.rtp.extensions, &(&1.identifier == identifier))

    if extension do
      buffer =
        Bunch.Struct.update_in(
          buffer,
          [:metadata, :rtp, :extensions],
          &delete(&1, identifier)
        )

      {extension, buffer}
    else
      {nil, buffer}
    end
  end

  @spec put(Buffer.t(), t()) :: Buffer.t()
  def put(buffer, extension) do
    Bunch.Struct.update_in(buffer, [:metadata, :rtp, :extensions], &[extension | &1])
  end

  defp delete(extensions, identifier) do
    Enum.reject(extensions, &(&1.identifier == identifier))
  end
end
