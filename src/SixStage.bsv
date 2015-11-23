import Types::*;
import ProcTypes::*;
import MemTypes::*;
import RFile::*;
import Decode::*;
import Exec::*;
import CsrFile::*;
import Fifo::*;
import Ehr::*;
import Btb::*;
import Scoreboard::*;
import Bht::*;
import GetPut::*;
import ClientServer::*;
import Memory::*;
import ICache::*;
import DCache::*;
import DCacheStQ::*;
import DCacheLHUSM::*;
import MemReqIDGen::*;
import CacheTypes::*;
import WideMemInit::*;
import MemUtil::*;
import Vector::*;
import FShow::*;
import MessageFifo::*;
import RefTypes::*;

// TODO: implement six-stage pipeline

module mkCore(
	CoreID id,
	WideMem iMem,
	RefDMem refDMem,
	Core ifc
);
    Ehr#(2, Addr)  pcReg <- mkEhr(?);
    CsrFile         csrf <- mkCsrFile(id);

	// I cache
	ICache iCache <- mkICache(iMem);

	// D cache
	MessageFifo#(2) toParentQ <- mkMessageFifo;
	MessageFifo#(2) fromParentQ <- mkMessageFifo;
`ifdef LHUSM
	DCache dCache <- mkDCacheLHUSM(
`elsif STQ
    DCache dCache <- mkDCacheStQ(
`else
    DCache dCache <- mkDCache(
`endif
		id,
		toMessageGet(fromParentQ),
		toMessagePut(toParentQ),
		refDMem
	);

	// mem req id
	MemReqIDGen memReqIDGen <- mkMemReqIDGen;




	interface MessageGet toParent = toMessageGet(toParentQ);
	interface MessagePut fromParent = toMessagePut(fromParentQ);

    method ActionValue#(CpuToHostData) cpuToHost if(csrf.started);
        let ret <- csrf.cpuToHost;
        return ret;
    endmethod

	method Bool cpuToHostValid = csrf.cpuToHostValid;

    method Action hostToCpu(Bit#(32) startpc) if ( !csrf.started );
        csrf.start;
        pcReg[0] <= startpc;
    endmethod
endmodule

