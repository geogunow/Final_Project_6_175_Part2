import Vector::*;
import CacheTypes::*;
import MessageFifo::*;
import Types::*;

// TODO: implement message router

module mkMessageRouter(
		Vector#(CoreNum, MessageGet) c2r,
        Vector#(CoreNum, MessagePut) r2c,
        MessageGet m2r,
        MessagePut r2m,
        Empty ifc 
	);

endmodule

