using BinDeps
@BinDeps.setup

liblzma = library_dependency("liblzma",aliases=["liblzma-5"])
if is_windows()
	using WinRPM
	provides(WinRPM.RPM,"liblzma5",liblzma,os = :Windows)
end
@BinDeps.install Dict(:liblzma=>:liblzma)
