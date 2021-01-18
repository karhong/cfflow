/**
 * The workflow engine is the entry point for all cfflow
 * implementation programmers to interact with workflow
 * definitions and instances.
 */
component singleton {

	public any function init(
		  required WorkflowImplementationFactory implementationFactory
		, required WorkflowLibrary               workflowLibrary
		, required WorkflowArgSubstitutor        workflowArgSubstitutor
	) {
		_setImplementationFactory( arguments.implementationFactory );
		_setWorkflowLibrary( arguments.workflowLibrary );
		_setWorkflowArgSubstitutor( arguments.workflowArgSubstitutor );

		return this;
	}

// ENGINE API
	public void function initializeInstance( required WorkflowInstance wfInstance, struct initialState={}, string initialActionId ) {
		if ( StructCount( arguments.initialState ) ) {
			arguments.wfInstance.setState( arguments.initialState );
		}

		doInitialAction(
			  wfInstance      = arguments.wfInstance
			, initialActionId = arguments.initialActionId ?: NullValue()
		);
	}

	public void function doInitialAction(
		  required WorkflowInstance wfInstance
		,          string           initialActionId = ""
	) {
		var wf             = _getWorkflowDefinition( arguments.wfInstance.getWorkflowId() );
		var actions        = wf.getInitialActions();
		var specificAction = Len( Trim( arguments.initialActionId ) );

		for( var action in actions ) {
			var useAction = !specificAction || action.getId() == arguments.initialActionId;

			if ( !useAction ) {
				continue;
			}

			if ( action.hasCondition() ) {
				useAction = evaluateCondition( wfInstance=arguments.wfInstance, wfCondition=action.getCondition() );
				if ( !useAction ) {
					continue;
				}
			}

			doAction( wfInstance=arguments.wfInstance, wfAction=action );
			return;
		}

		throw( "The workflow [#wf.getId()#] could not be initialized. No initial actions met their conditional criteria.", "cfflow.no.initial.actions.runnable" );
	}

	public void function doAction( required WorkflowInstance wfInstance, required WorkflowAction wfAction ) {
		var wfResult = getResultToExecute( arguments.wfInstance, arguments.wfAction );
		var impl = arguments.wfInstance.getWorkflowImplementation();

		doResult(
			  wfInstance = arguments.wfInstance
			, wfResult   = wfResult
		);

		impl.recordAction(
			  workflowId   = arguments.wfInstance.getWorkflowId()
			, instanceArgs = arguments.wfInstance.getInstanceArgs()
			, state        = arguments.wfInstance.getState()
			, actionId     = arguments.wfAction.getId()
			, resultId     = wfResult.getId()
			, transitions  = wfResult.getTransitions()
		);

		if ( arguments.wfInstance.isComplete() ) {
			impl.setComplete(
				  workflowId   = arguments.wfInstance.getWorkflowId()
				, instanceArgs = arguments.wfInstance.getInstanceArgs()
			);
		}
	}

	public WorkflowImplementation function getImplementation( required Workflow wf ) {
		return _getImplementationFactory().getWorkflowImplementation( wf.getClass() );
	}

	public void function doResult( required WorkflowInstance wfInstance, required WorkflowResult wfResult ) {
		var preFunctions  = filterFunctionsToExecute( arguments.wfInstance, arguments.wfResult.getPreFunctions() );
		var postFunctions = filterFunctionsToExecute( arguments.wfInstance, arguments.wfResult.getPostFunctions() );
		var transitions   = arguments.wfResult.getTransitions();

		for( var fn in preFunctions ) {
			doFunction( wfInstance=arguments.wfInstance, wfFunction=fn );
		}

		for( var transition in transitions ) {
			doTransition( wfInstance=arguments.wfInstance, wfTransition=transition );
		}

		for( var fn in postFunctions ) {
			doFunction( wfInstance=arguments.wfInstance, wfFunction=fn );
		}
	}

	public void function doTransition(
		  required WorkflowInstance  wfInstance
		, required WorkflowTransition wfTransition
	) {
		var impl = arguments.wfInstance.getWorkflowImplementation();

		impl.setStepStatus(
			  workflowId   = arguments.wfInstance.getWorkflowId()
			, instanceArgs = arguments.wfInstance.getInstanceArgs()
			, step         = arguments.wfTransition.getStep()
			, status       = arguments.wfTransition.getStatus()
		);

		if ( arguments.wfTransition.getStatus() == "active" ) {
			scheduleAutoActions(
				  stepId     = arguments.wfTransition.getStep()
				, wfInstance = arguments.wfInstance
			);
		} else {
			unScheduleAutoActions(
				  stepId     = arguments.wfTransition.getStep()
				, wfInstance = arguments.wfInstance
			);
		}
	}

	public WorkflowResult function getResultToExecute( required WorkflowInstance wfInstance, required WorkflowAction wfAction ) {
		var conditionalResults = arguments.wfAction.getConditionalResults();

		for( var result in conditionalResults ) {
			if ( evaluateCondition( result.getCondition(), arguments.wfInstance ) ) {
				return result;
			}
		}

		return arguments.wfAction.getDefaultResult();
	}

	public boolean function evaluateCondition(
		  required WorkflowCondition wfCondition
		, required WorkflowInstance  wfInstance
		,          struct            args
	) {
		var condition       = _getImplementationFactory().getCondition( id=arguments.wfCondition.getRef() );
		var substitutedArgs = arguments.args ?: substituteArgs( arguments.wfCondition.getArgs(), arguments.wfInstance );
		var result          = condition.evaluate(
			  wfInstance = arguments.wfInstance
			, args       = substitutedArgs
		);

		if ( !result && ArrayLen( arguments.wfCondition.getOrConditions() ) ) {
			for( var orCondition in arguments.wfCondition.getOrConditions() ) {
				if ( evaluateCondition( orCondition, arguments.wfInstance ) ) {
					result = true;
					break;
				}
			}
		}

		if ( result && ArrayLen( arguments.wfCondition.getAndConditions() ) ) {
			for( var andCondition in arguments.wfCondition.getAndConditions() ) {
				if ( !evaluateCondition( andCondition, arguments.wfInstance ) ) {
					result = false;
					break;
				}
			}
		}

		if ( wfCondition.getNot() ) {
			return !result;
		}

		return result;
	}

	public void function doFunction( required WorkflowInstance wfInstance, required WorkflowFunction wfFunction ) {
		var fn   = _getImplementationFactory().getFunction( id=arguments.wfFunction.getRef() );
		var args = substituteArgs( arguments.wfFunction.getArgs(), arguments.wfInstance );

		fn.do(
			  wfInstance = arguments.wfInstance
			, args       = args
		);
	}

	public array function filterFunctionsToExecute( required WorkflowInstance wfInstance, required array functions ) {
		var filtered = [];

		for( var fn in arguments.functions ) {
			if ( !fn.hasCondition() || evaluateCondition( fn.getCondition(), arguments.wfInstance ) ) {
				filtered.append( fn );
			}
		}

		return filtered;
	}

	public WorkflowStep function getStepForInstance( required WorkflowInstance wfInstance, required string stepId ) {
		var steps = _getWorkflowDefinition( arguments.wfInstance.getWorkflowId() ).getSteps();

		for( var step in steps ) {
			if ( step.getId() == arguments.stepId ) {
				return step;
			}
		}
	}

	public void function scheduleAutoActions( required WorkflowInstance wfInstance, required string stepId ) {
		var wfStep = getStepForInstance( wfInstance=arguments.wfInstance, stepId=arguments.stepId );

		if ( !IsNull( wfStep ) && wfStep.hasAutoActions() ) {
			if ( wfStep.hasAutoActionTimers() ) {
				arguments.wfInstance.getWorkflowImplementation().scheduleAutoActions(
					  workflowId   = arguments.wfInstance.getWorkflowId()
					, instanceArgs = arguments.wfInstance.getInstanceArgs()
					, stepId       = arguments.stepId
					, timers       = wfStep.getAutoActionTimers()
				);
			} else {
				// immediate execution
				doAutoActions( wfInstance=arguments.wfInstance, wfStep=wfStep );
			}
		}
	}

	public void function unScheduleAutoActions() {
		var wfStep = getStepForInstance( wfInstance=arguments.wfInstance, stepId=arguments.stepId );

		if ( !IsNull( wfStep ) && wfStep.hasAutoActions() ) {
			if ( wfStep.hasAutoActionTimers() ) {
				arguments.wfInstance.getWorkflowImplementation().unScheduleAutoActions(
					  workflowId   = arguments.wfInstance.getWorkflowId()
					, instanceArgs = arguments.wfInstance.getInstanceArgs()
					, stepId       = arguments.stepId
				);
			}
		}
	}

	public boolean function doAutoActions(
		  required WorkflowInstance wfInstance
		,          string           stepId = ""
		,          WorkflowStep     wfStep = getStepForInstance( arguments.wfInstance, arguments.stepId )
	) {
		if( !IsNull( arguments.wfStep ) ) {
			for( var action in arguments.wfStep.getActions() ) {
				if ( action.getIsAutomatic() ) {
					if ( !action.hasCondition() || evaluateCondition( wfInstance=arguments.wfInstance, wfCondition=action.getCondition() ) ) {
						doAction( wfInstance=arguments.wfInstance, wfAction=action );
						return true;
					}
				}
			}
		}
		return false;
	}

	public any function substituteArgs( required any args, required WorkflowInstance wfInstance ) {
		return _getWorkflowArgSubstitutor().substitute( arguments.args, arguments.wfInstance );
	}

// PRIVATE HELPERS
	private any function _getWorkflowDefinition( required string workflowId ) {
		return _getWorkflowLibrary().getWorkflow( arguments.workflowId );
	}

// GETTERS AND SETTERS
	private any function _getImplementationFactory() {
	    return _implementationFactory;
	}
	private void function _setImplementationFactory( required any implementationFactory ) {
	    _implementationFactory = arguments.implementationFactory;
	}

	private any function _getWorkflowLibrary() {
	    return _workflowLibrary;
	}
	private void function _setWorkflowLibrary( required any workflowLibrary ) {
	    _workflowLibrary = arguments.workflowLibrary;
	}

	private any function _getWorkflowArgSubstitutor() {
	    return _workflowArgSubstitutor;
	}
	private void function _setWorkflowArgSubstitutor( required any workflowArgSubstitutor ) {
	    _workflowArgSubstitutor = arguments.workflowArgSubstitutor;
	}

}