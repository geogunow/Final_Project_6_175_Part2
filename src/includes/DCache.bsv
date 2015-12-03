import CacheTypes::*;
import Vector::*;
import FShow::*;
import MemTypes::*;
import Types::*;
import ProcTypes::*;
import Fifo::*;
import Ehr::*;
import RefTypes::*;


typedef enum{Ready, StartMiss, SendFillReq, WaitFillResp, Resp} CacheStatus 
    deriving(Eq, Bits);
module mkDCache#(CoreID id)(
		MessageGet fromMem,
		MessagePut toMem,
		RefDMem refDMem, // debug: reference data mem
		DCache ifc);

    // Track the cache state
    Reg#(CacheStatus) status <- mkReg(Ready);

    // The cache memory
    Vector#(CacheRows, Reg#(CacheLine)) dataArray <- replicateM(mkRegU);
    Vector#(CacheRows, Reg#(CacheTag)) tagArray <- replicateM(mkRegU);
    Vector#(CacheRows, Reg#(MSI)) privArray <- replicateM(mkReg(I));

    // Book keeping
    Fifo#(2, Data) hitQ <- mkBypassFifo;
    Fifo#(1, MemReq) reqQ <- mkBypassFifo;
    Reg#(MemReq) missReq <- mkRegU;

    rule doReq (status == Ready);

        // get request from queue
        MemReq r = reqQ.first;
        reqQ.deq;

        // calculate cache index and tag
        $display("[Cache] Processing request");
        CacheWordSelect sel = getWordSelect(r.addr);
        CacheIndex idx = getIndex(r.addr);
        CacheTag tag = getTag(r.addr);

        // check if in cache
        let hit = False;
        if (tagArray[idx] == tag && privArray[idx] > I) hit = True;

        if (hit) begin
            if (r.op == Ld) begin
                $display("[Cache] Load hit");
                hitQ.enq(dataArray[idx][sel]);
            end
            else begin // it is a store
                if (privArray[idx] == M) begin
                    $display("[Cache] Write hit");
                    dataArray[idx][sel] <= r.data;
                end
                else begin
                    $display("[Cache] No write privledge");
                    missReq <= r;
                    status <= SendFillReq;
                end
            end
        end
        else begin
            $display("[Cache] Cache miss");
            missReq <= r;
            status <= StartMiss;
        end
    endrule


    rule startMiss (status == StartMiss);

        // calculate cache index and tag
        $display("[[Cache]] Start Miss");
        CacheWordSelect sel = getWordSelect(missReq.addr);
        CacheIndex idx = getIndex(missReq.addr);
        let tag = tagArray[idx];

        if (privArray[idx] != I) begin
           
           // Invalidate cache line
           privArray[idx] <= I;

           // Determine if a valid cache line needs to write back
           Maybe#(CacheLine) line;
           if (privArray[idx] == M) line = Valid(dataArray[idx]);
           else line = Invalid;
           
           // Send cache line back to main memory
           let addr = {tag, idx, sel, 2'b0};
           toMem.enq_resp( CacheMemResp {child: id, 
                                  addr: addr, 
                                  state: I, 
                                  data: line});
        end
        status <= SendFillReq;

    endrule


    rule sendFillReq (status == SendFillReq);

        $display("[[Cache]] Send Fill Request");

        // send upgrade request, S if load; otherwise M
        let upg = (missReq.op == Ld)? S : M;
        toMem.enq_req( CacheMemReq {child: id, addr:missReq.addr, state: upg});
        status <= WaitFillResp;

    endrule


    rule waitFillResp (status == WaitFillResp && fromMem.hasResp);
        
        // calculate cache index and tag
        $display("[[Cache]] Wait Fill Response");
        CacheWordSelect sel = getWordSelect(missReq.addr);
        CacheIndex idx = getIndex(missReq.addr);
        let tag = getTag(missReq.addr);
        
        // fill cache line with data
        CacheMemResp x = ?;
        case (fromMem.first) matches
            tagged Resp .resp : x = resp;
        endcase
        //FIXME: look here
        let line = fromMaybe(?, x.data);
            
        /// check load
        if (missReq.op == Ld) begin
            // enqueue result into hit queue
            hitQ.enq(line[sel]);
        end
        else begin
            // store
            line[sel] = missReq.data;
        end
        
        // update cache line tag and privledge
        tagArray[idx] <= tag;
        privArray[idx] <= x.state;
        
        // dequeue memory response
        fromMem.deq;
        
        // reset status
        status <= Resp;
    endrule


    rule sendProc (status == Resp);
        
        CacheIndex idx = getIndex(missReq.addr);
        CacheWordSelect sel = getWordSelect(missReq.addr);
        
        // enqueue load into hit queue
        //FIXME c2p??
        if (missReq.op == Ld) hitQ.enq(dataArray[idx][sel]);
        
        status <= Ready;

    endrule


    method Action req(MemReq r);
        reqQ.enq(r);
    endmethod


    method ActionValue#(Data) resp;
        $display("[Cache] Processing response");
        hitQ.deq;
        return hitQ.first;
    endmethod


endmodule
