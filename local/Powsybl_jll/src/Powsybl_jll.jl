# Use baremodule to shave off a few KB from the serialized `.ji` file
baremodule Powsybl_jll
using Base
using Base: UUID
import JLLWrappers

JLLWrappers.@generate_main_file_header("Powsybl")
JLLWrappers.@generate_main_file("Powsybl", UUID("b8c81e45-bfcc-5af0-87df-fd7619bc5515"))
end  # module Powsybl_jll
