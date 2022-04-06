module app;

import std.algorithm.iteration : map;
import std.array : array;
import std.getopt;
import std.mmfile;
import std.random : uniform;
import std.range : iota;
import std.stdio : File, writefln;
import siryul;
import nspc;

void main(string[] args) {
	ushort baseAddress;
	ushort newBaseAddress = 0x4800;
	bool packMode;
	string outFile = "test.ebm";
	string configFile;
	auto help = getopt(args,
		"b|base", &baseAddress,
		"n|newbase", &newBaseAddress,
		"p|packfile", &packMode,
		"c|configfile", &configFile,
		"o|outfile", &outFile,
	);
	if (help.helpWanted) {
		defaultGetoptPrinter("", help.options);
		return;
	}
	Config config;
	if (configFile !is null) {
		config = fromFile!(Config, YAML)(configFile);
	}
	auto fileRaw = cast(ubyte[])(new MmFile(args[1]))[].dup;
	if (packMode) {
		if (baseAddress == 0) {
			baseAddress = (cast(ushort[])(fileRaw[0 .. 4]))[1];
		}
		fileRaw = fileRaw[4 .. $];
	}
	auto song = loadSong(baseAddress, fileRaw);
	song.baseAddress = newBaseAddress;
	if (config.randomizeNotes) {
		byte[12] noteMapping = iota(0, 12).map!(x => cast(byte)uniform(config.lowerNoteAdjustment, config.upperNoteAdjustment)).array;
		song.transposeNotes(noteMapping);
	} else {
		song.transposeNotes(config.noteMapping);
	}
	song.remapInstruments(config.instrumentMapping);
	writefln!"%($%04X %)"(song.phraseHeaders);
	writefln!"%($%04X %)"(song.phraseAddresses);
	with (File(outFile, "w")) {
		const data = song.toRaw;
		if (packMode) {
			rawWrite([cast(ushort)data.length, song.baseAddress]);
		}
		rawWrite(data);
	}
}