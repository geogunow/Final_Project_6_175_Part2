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

    // for LR/SC, which enable atomic memory access for multicore cooperation
    Reg#(Maybe#(CacheLineAddr)) linkAddr <- mkReg(Invalid);

    rule doReq (status == Ready);

        // get request from queue
        MemReq r = reqQ.first;
        reqQ.deq;

        // calculate cache index and tag
        CacheWordSelect sel = getWordSelect(r.addr);
        CacheIndex idx = getIndex(r.addr);
        CacheTag tag = getTag(r.addr);

        // check if in cache
        let hit = False;
        if (tagArray[idx] == tag && privArray[idx] > I) hit = True;

        // check whether to proceed in store conditional
        let proceed = False;
        if (r.op == Sc) begin
            if (isValid(linkAddr)) begin
                if (fromMaybe(?, linkAddr) == getLineAddr(r.addr)) begin
                    proceed = True;
                end
                // regardless of success, linkAddr no longer valid
                linkAddr <= tagged Invalid;
            end
        end
        else proceed = True;


        if (!proceed) begin
            hitQ.enq(scFail);
            refDMem.commit(r, Invalid, Valid(scFail));
        end
        else begin
            if (hit) begin
                if (r.op == Ld || r.op == Lr) begin
                    hitQ.enq(dataArray[idx][sel]);
                    refDMem.commit(r, Valid(dataArray[idx]), 
                                    Valid(dataArray[idx][sel]));
                    if (r.op == Lr) begin
                        linkAddr <= tagged Valid getLineAddr(r.addr);
                    end
                end 
                else begin
                    // Store (Sc or St)
                    if (privArray[idx] == M) begin
                        dataArray[idx][sel] <= r.data;
                        if (r.op == Sc) begin
                            hitQ.enq(scSucc);
                            refDMem.commit(r, Valid(dataArray[idx]), Valid(scSucc));
                        end
                        else refDMem.commit(r, Valid(dataArray[idx]), Invalid);
                    end
                    else begin
                        missReq <= r;
                        status <= SendFillReq;
                    end
                end
            end
            else begin
                missReq <= r;
                status <= StartMiss;
            end
        end
                        
    endrule


    rule startMiss (status == StartMiss);

        // calculate cache index and tag
        CacheWordSelect sel = getWordSelect(missReq.addr);
        CacheIndex idx = getIndex(missReq.addr);
        let tag = tagArray[idx];

        if (privArray[idx] != I) begin
           
           // Invalidate cache line
           privArray[idx] <= I;
           if (isValid(linkAddr) && 
               fromMaybe(?, linkAddr) == getLineAddr(missReq.addr)) begin
               linkAddr <= Invalid;
           end

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

        // send upgrade request, S if load; otherwise M
        let upg = (missReq.op == Ld || missReq.op == Lr)? S : M;
        toMem.enq_req( CacheMemReq {child: id, addr:missReq.addr, state: upg});
        status <= WaitFillResp;

    endrule


    rule waitFillResp (status == WaitFillResp && fromMem.hasResp);
       
        // calculate cache index and tag
        CacheWordSelect sel = getWordSelect(missReq.addr);
        CacheIndex idx = getIndex(missReq.addr);
        let tag = getTag(missReq.addr);
        
        // get response
        CacheMemResp x = ?;
        case (fromMem.first) matches
            tagged Resp .resp : x = resp;
        endcase
        
        // create cache line
        CacheLine line;
        if (isValid(x.data)) line = fromMaybe(?, x.data);
        else line = dataArray[idx];

        // check 
        Bool check = False;
        if (missReq.op == St) begin
            let old_line = isValid(x.data) ? fromMaybe(?, x.data) : dataArray[idx];
            refDMem.commit(missReq, Valid(old_line), Invalid);
            line[sel] = missReq.data;
        end
        else if (missReq.op == Sc) begin
            if (isValid(linkAddr) && 
                fromMaybe(?, linkAddr) == getLineAddr(missReq.addr)) begin

                let old_line = fromMaybe(?, x.data);
                refDMem.commit(missReq, Valid(old_line), Valid(scSucc));
                line[sel] = missReq.data;
                hitQ.enq(scSucc);

            end
            else begin
                hitQ.enq(scFail);
            end
        end
        dataArray[idx] <= line;
        
        // update cache line tag and privledge
        tagArray[idx] <= tag;
        privArray[idx] <= x.state;
        if (x.state == I) begin
           if (isValid(linkAddr) && 
               fromMaybe(?, linkAddr) == getLineAddr(x.addr)) begin
               linkAddr <= Invalid;
           end
        end
        
        // dequeue memory response
        fromMem.deq;

        // reset status
        status <= Resp;
    endrule


    rule sendProc (status == Resp);
        
        CacheIndex idx = getIndex(missReq.addr);
        CacheWordSelect sel = getWordSelect(missReq.addr);
        
        // enqueue load into hit queue
        if (missReq.op == Ld || missReq.op == Lr) begin
            hitQ.enq(dataArray[idx][sel]);
            refDMem.commit(missReq, Valid(dataArray[idx]), 
                            Valid(dataArray[idx][sel]));
            
            if (missReq.op == Lr) begin
                linkAddr <= tagged Valid getLineAddr(missReq.addr);
            end
        end
        
        status <= Ready;

    endrule

    
    rule dng (status != Resp);
        
        // get response
        CacheMemReq x = ?;
        case (fromMem.first) matches
            tagged Req .req : x = req;
        endcase
        
        // calculate cache index
        CacheWordSelect sel = getWordSelect(x.addr);
        CacheIndex idx = getIndex(x.addr);
        let tag = getTag(x.addr);
        

        if (privArray[idx] > x.state) begin

           // Determine if a valid cache line needs to write back
           Maybe#(CacheLine) line;
           if (privArray[idx] == M) line = Valid(dataArray[idx]);
           else line = Invalid;

           // Send cache line back to main memory
           let addr = {tag, idx, sel, 2'b0};
           toMem.enq_resp( CacheMemResp {child: id, 
                                  addr: addr, 
                                  state: x.state, 
                                  data: line});
            
            // change cache state
            privArray[idx] <= x.state;
            if (x.state == I) begin
               if (isValid(linkAddr) && 
                   fromMaybe(?, linkAddr) == getLineAddr(x.addr)) begin
                   linkAddr <= Invalid;
               end
           end
        end

        // address has been downgraded
        fromMem.deq;
    endrule
 
 

    method Action req(MemReq r);
        reqQ.enq(r);
        refDMem.issue(r);
    endmethod


    method ActionValue#(Data) resp;
        hitQ.deq;
        return hitQ.first;
    endmethod


endmodule
