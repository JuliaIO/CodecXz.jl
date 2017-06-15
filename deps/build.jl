using BinDeps
@BinDeps.setup

liblzma = library_dependency("liblzma",aliases=["liblzma5"])
if is_windows()
	using WinRPM
	provides(WinRPM.RPM,"liblzma5",liblzma,os = :Windows)
	@BinDeps.install Dict(:liblzma=>:liblzma)
end
