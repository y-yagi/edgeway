module Edgeway
  module Cache
    # A year. In wasm, Integers are 32 bits: epoch seconds plus an expires_in
    # stop fitting in 2038, so a longer expiry is refused rather than allowed
    # to overflow.
    MAX_EXPIRES_IN = 31_536_000
  end
end
