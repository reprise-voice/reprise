### Call priorities

Call priorities are designed to help processing important or VIP calls with special care (including "pushing' them through queues). Generally, the higher (larger) priority of a call, the faster it should be answered.

#### Priority support in Callflows
There is a `call-priority` call time variable that can be set using `cf_set_variable` module:

Usage example for `cf_set_variable` module:

	 "flow": {
	     "data": {
	         "variable": "call_priority",
	         "value": "6",
	         "channel": "a"
	     },
	     "module": "set_variable",
	     "children": {
	     }
	 }

The corresponding module `cf_branch_variable` forks a callflow to branches depending on variable value. If some key in child branch matches the value, the callflow will go that way.

As for now `cf_set_variable` and `cf_branch_variable` modules only support  `call_priority` variable.

Usage example for `cf_branch_variable` module:

	 "flow": {
	     "data": {
             "variable": "call_priority"
	     },
	     "module": "branch_variable",
         "children": {
             "7": {
                 "data": {
                     "id": "2e7a812a6e9405ad99ea1493123df03a",
                     "timeout": "20"
                 },
                 "module": "device",
                 "children": {}
             },
             "_": {
                 "data": {
                     "id": "4f18af4f889a368e8153232a7e891209",
                     "timeout": "20",
                 },
                 "module": "device",
                 "children": {}
             }
	     }
	 }
