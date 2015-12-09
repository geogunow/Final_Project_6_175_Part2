import CacheTypes::*;
import Vector::*;
import FShow::*;
import MemTypes::*;
import Types::*;
import ProcTypes::*;
import Fifo::*;
import Ehr::*;
import RefTypes::*;
import StQ::*;


typedef enum{Ready, StartMiss, SendFillReq, WaitFillResp, Resp} CacheStatus 
    deriving(Eq, Bits);
module mkDCacheLHUSM#(CoreID id)(
		MessageGet fromMem,
		MessagePut toMem,
		RefDMem refDMem, // debug: reference data mem
		DCache ifc
	);

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
    
    // store queue
    StQ#(StQSize) stq <-mkStQ;

    // register for the SC response
    Reg#(Maybe#(Data)) scResp <- mkReg(Invalid);

    Reg#(Bool) loadMiss <- mkReg(False);

    rule doStore (reqQ.first.op == St);
        
        $display("[Cache] Enqueueing store");

        // enqueue store request
        MemReq r = reqQ.first;
        reqQ.deq;
        stq.enq(r);

    endrule


    rule doSc (status == Ready && reqQ.first.op == Sc && !stq.notEmpty);
        
        $display("[Cache] Doing Sc");
        // get request from queue
        MemReq r = reqQ.first;
        reqQ.deq;

        // calculate cache index and tag
        CacheWordSelect sel = getWordSelect(r.addr);
        CacheIndex idx = getIndex(r.addr);
        CacheTag tag = getTag(r.addr);


        // check whether to proceed in store conditional
        if (linkAddr matches tagged Valid .la &&& la == getLineAddr(r.addr)) begin
            
            // check if in cache
            if (tagArray[idx] == tag && privArray[idx] > I) begin
                
                // check write privledge
                if (privArray[idx] == M) begin
                    hitQ.enq(scSucc);
                    dataArray[idx][sel] <= r.data;
                    refDMem.commit(r, Valid(dataArray[idx]), Valid(scSucc));
                    linkAddr <= Invalid;
                end
                else begin
                    missReq <= r;
                    status <= SendFillReq;
                end
            end
            else begin
                missReq <= r;
                status <= StartMiss;
            end
        end
        else begin
            hitQ.enq(scFail);
            refDMem.commit(r, Invalid, Valid(scFail));
            linkAddr <= Invalid;
        end

    endrule

    
    rule doFence (status == Ready && reqQ.first.op == Fence && !stq.notEmpty);
        $display("[Cache] Doing fence");
        reqQ.deq;
        refDMem.commit(reqQ.first, Invalid, Invalid);
    endrule


    rule startMiss (status == StartMiss);
        $display("[Cache] Start miss");

        // calculate cache index and tag
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
        if (isValid(linkAddr) && 
            fromMaybe(?, linkAddr) == getLineAddr(missReq.addr)) begin
               linkAddr <= Invalid;
        end

    endrule


    rule sendFillReq (status == SendFillReq);
        $display("[Cache] SendFillReq");

        // send upgrade request, S if load; otherwise M
        let upg = (missReq.op == Ld || missReq.op == Lr)? S : M;
        toMem.enq_req( CacheMemReq {child: id, addr:missReq.addr, state: upg});
        status <= WaitFillResp;

    endrule


    rule debugWFR (status == WaitFillResp && fromMem.hasResp);
        $display("[Cache] guards say WFR should fire");
    endrule
    rule debugWFR2 (status == WaitFillResp && fromMem.hasResp);
        CacheMemResp x = fromMem.first.Resp;
        $display("[Cache] WFR has valid resp");
    endrule

    rule waitFillResp (status == WaitFillResp && fromMem.hasResp);
       
        $display("[Cache] WaitFillResp");
        // calculate cache index and tag
        CacheWordSelect sel = getWordSelect(missReq.addr);
        CacheIndex idx = getIndex(missReq.addr);
        let tag = getTag(missReq.addr);
        
        // get response
        CacheMemResp x = fromMem.first.Resp;
        
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
            stq.deq;
            $display("[Cache] Store miss commit");
        end
        else if (missReq.op == Sc) begin
            if (isValid(linkAddr) && 
                fromMaybe(?, linkAddr) == getLineAddr(missReq.addr)) begin

                let old_line = dataArray[idx];
                if (isValid(x.data)) old_line = fromMaybe(?, x.data);
                line[sel] = missReq.data;
                scResp <= Valid(scSucc);
                $display("[Cache] SC miss commit");

            end
            else begin
                scResp <= Valid(scFail);
            end
            linkAddr <= Invalid;
        end
                        
        dataArray[idx] <= line;
        
        // update cache line tag and privledge
        tagArray[idx] <= tag;
        privArray[idx] <= x.state;
        
        // dequeue memory response
        fromMem.deq;

        // reset status
        status <= Resp;
    endrule


    rule sendCore (status == Resp);
        
        $display("[Cache] Send Core");
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
        else if (missReq.op == Sc) begin
            if (isValid(scResp)) hitQ.enq(fromMaybe(?, scResp));
            refDMem.commit(missReq, Invalid, scResp);
            scResp <= Invalid;
        end
        
        status <= Ready;
        loadMiss <= False;

    endrule


    rule doLoad ((reqQ.first.op == Ld || (reqQ.first.op == Lr && !stq.notEmpty))
        && !loadMiss);

        // get request from queue
        $display("[Cache] Doing load");
        MemReq r = reqQ.first;

        // calculate cache index and tag
        CacheWordSelect sel = getWordSelect(r.addr);
        CacheIndex idx = getIndex(r.addr);
        CacheTag tag = getTag(r.addr);

        let hit = False;
        if (status == Ready) begin

            // dequeue from request queue
            reqQ.deq;
            $display("[Cache] Doing load ... status ready");
            
            // search stb
            let x = stq.search(r.addr);
            if (isValid(x)) begin
                hitQ.enq(fromMaybe(?, x));
                refDMem.commit(r, Invalid, x);
                hit = True;
            end
            else begin

                // check if in cache
                if (tagArray[idx] == tag && privArray[idx] > I) begin

                    hitQ.enq(dataArray[idx][sel]);
                    refDMem.commit(r, Valid(dataArray[idx]), 
                                    Valid(dataArray[idx][sel]));
                    hit = True;
                
                end
                else begin
                    missReq <= r;
                    status <= StartMiss;
                    loadMiss <= True;
                end
            end
                
        end
        else begin

            // cache miss is begin processed, check if it's a store
            // and that nothing is coming back this cycle
            $display("[Cache] Doing load ... status NOT ready");
            if (missReq.op == St) $display("[Cache] miss req curr store");
            else if (missReq.op == Ld) $display("[Cache] miss req curr Ld");
            if (fromMem.hasResp) $display("[Cache] fromMem has a response");
            if (missReq.op == St && !fromMem.hasResp) begin
                
                // check if load hit
                let x = stq.search(r.addr);
                if (isValid(x)) begin
                    
                    $display("[Cache] Load hit under store miss");
                    hitQ.enq(fromMaybe(?, x));
                    refDMem.commit(r, Invalid, x);
                    hit = True;
                    
                    // dequeue request
                    reqQ.deq;
                end
                else if (tagArray[idx] == tag && privArray[idx] > I) begin
                    
                    $display("[Cache] Load hit under store miss");
                    hitQ.enq(dataArray[idx][sel]);
                    refDMem.commit(r, Valid(dataArray[idx]), 
                                    Valid(dataArray[idx][sel]));
                    hit = True;
                    
                    // dequeue request
                    reqQ.deq;
                end
            end
        end
        
        if (hit && r.op == Lr) linkAddr <= tagged Valid getLineAddr(r.addr);


    endrule



    
    rule dng (status != Resp && !fromMem.hasResp);
        
        $display("[Cache] DOWNGRADING");
        // get response
        CacheMemReq x = fromMem.first.Req;
        
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
            if (linkAddr matches tagged Valid .la &&& la == getLineAddr(x.addr)
                && x.state == I) linkAddr <= Invalid;
        end

        // address has been downgraded
        fromMem.deq;
    endrule


    rule mvStqToCache (status == Ready && stq.notEmpty && 
        (!reqQ.notEmpty || reqQ.first.op != Ld));
        $display("[Cache] Process store");

        // get request from store queue
        MemReq r <- stq.issue;

        // calculate cache index and tag
        CacheWordSelect sel = getWordSelect(r.addr);
        CacheIndex idx = getIndex(r.addr);
        CacheTag tag = getTag(r.addr);

        if (tagArray[idx] == tag && privArray[idx] > I) begin
            if (privArray[idx] == M) begin
                // store hit
                dataArray[idx][sel] <= r.data;
                refDMem.commit(r, Valid(dataArray[idx]), Invalid);
                stq.deq;
                if (linkAddr matches tagged Valid .la &&& la == getLineAddr(r.addr))
                    linkAddr <= Invalid;
            end
            else begin
                // no write privledge
                missReq <= r;
                status <= SendFillReq;
            end
        end
        else begin
            // store miss
            missReq <= r;
            status <= StartMiss;
        end
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
