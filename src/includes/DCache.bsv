import CacheTypes::*;
import Vector::*;
import FShow::*;
import MemTypes::*;
import Types::*;
import ProcTypes::*;
import Fifo::*;
import Ehr::*;
import RefTypes::*;

// TODO: implement blocking D cache

module mkDCache#(CoreID id)(
		MessageGet fromMem,
		MessagePut toMem,
		RefDMem refDMem, // debug: reference data mem
		DCache ifc
	);

endmodule
