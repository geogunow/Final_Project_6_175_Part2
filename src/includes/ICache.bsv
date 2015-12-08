import CacheTypes::*;
import Types::*;
import ProcTypes::*;
import Fifo::*;
import Vector::*;
import MemTypes::*;
import MemUtil::*;
import SimMem::*;


typedef enum{Ready, StartMiss, SendFillReq, WaitFillResp} CacheStatus 
    deriving(Eq, Bits);
module mkICache(WideMem mem, ICache ifc);

    // Track the cache state
    Reg#(CacheStatus) status <- mkReg(Ready);

    // The cache memory
    Vector#(CacheRows, Reg#(CacheLine)) dataArray <- replicateM(mkRegU);
    Vector#(CacheRows, Reg#(Maybe#(CacheTag))) 
            tagArray <- replicateM(mkReg(Invalid));
    Vector#(CacheRows, Reg#(Bool)) dirtyArray <- replicateM(mkReg(False));

    // Book keeping
    Fifo#(2, Data) hitQ <- mkBypassFifo;
    Reg#(Addr) missAddr <- mkRegU;
    Fifo#(2, MemReq) memReqQ <- mkCFFifo;
    Fifo#(2, CacheLine) memRespQ <- mkCFFifo;


    function CacheWordSelect getWord(Addr addr) = truncate(addr >> 2);
    function CacheIndex getIndex(Addr addr) = truncate(addr >> 6);
    function CacheTag getTag(Addr addr) = truncateLSB(addr);

    rule sendFillReq (status == StartMiss);

<<<<<<< HEAD
=======
        //$display("[[ICache]] Send Fill Request");
>>>>>>> 6a4fe686aa91968d3a8e42df723da5a45a4a0f2e
        memReqQ.enq(MemReq {op: Ld, addr: missAddr, data:?});
        status <= WaitFillResp;

    endrule


    rule waitFillResp (status == WaitFillResp);
        
        // calculate cache index and tag
<<<<<<< HEAD
=======
        //$display("[[ICache]] Wait Fill Response");
>>>>>>> 6a4fe686aa91968d3a8e42df723da5a45a4a0f2e
        CacheWordSelect sel = getWord(missAddr);
        CacheIndex idx = getIndex(missAddr);
        let tag = getTag(missAddr);
        
        // set cache line with data
        let line = memRespQ.first;
        tagArray[idx] <= Valid(tag);
        
        // enqueue result into hit queue
        hitQ.enq(line[sel]);
        dataArray[idx] <= line;
        
        // dequeue response queue
        memRespQ.deq;

        // reset status
        status <= Ready;
    endrule


    rule sendToMemory;

        // dequeue to get DRAM request
<<<<<<< HEAD
=======
        //$display("[[ICache]] Sending to DRAM");
>>>>>>> 6a4fe686aa91968d3a8e42df723da5a45a4a0f2e
        memReqQ.deq;
        let r = memReqQ.first;

        // translate data to cache line
        CacheIndex idx = getIndex(r.addr);
        CacheLine line = dataArray[idx];
        
        // create enable signal
        Bit#(CacheLineWords) en;
        if (r.op == St) en = '1;
        else en = '0; 

        mem.req(WideMemReq{
            write_en: en,
            addr: r.addr,
            data: line
        } );

    endrule


    rule getFromMemory;

        // get DRAM response
<<<<<<< HEAD
=======
        //$display("[[ICache]] Getting from DRAM");
>>>>>>> 6a4fe686aa91968d3a8e42df723da5a45a4a0f2e
        let line <- mem.resp();
        memRespQ.enq(line);
    
    endrule


    method Action req(Addr a) if (status == Ready);
    
        // calculate cache index and tag
<<<<<<< HEAD
=======
        //$display("[ICache] Processing request");
>>>>>>> 6a4fe686aa91968d3a8e42df723da5a45a4a0f2e
        CacheWordSelect sel = getWord(a);
        CacheIndex idx = getIndex(a);
        CacheTag tag = getTag(a);

        // check if in cache
        let hit = False;
        if (tagArray[idx] matches tagged Valid .currTag 
            &&& currTag == tag) hit = True;

        // check load
        if (hit) begin
<<<<<<< HEAD
            hitQ.enq(dataArray[idx][sel]);
        end
        else begin
=======
            //$display("[ICache] Load hit");
            hitQ.enq(dataArray[idx][sel]);
        end
        else begin
            //$display("[ICache] Load miss");
>>>>>>> 6a4fe686aa91968d3a8e42df723da5a45a4a0f2e
            missAddr <= a;
            status <= StartMiss;
        end
    endmethod


    method ActionValue#(Data) resp;
<<<<<<< HEAD
=======
        //$display("[ICache] Processing response");
>>>>>>> 6a4fe686aa91968d3a8e42df723da5a45a4a0f2e
        hitQ.deq;
        return hitQ.first;
    endmethod


endmodule


